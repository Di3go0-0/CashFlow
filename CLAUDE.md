# CashFlow

App iOS personal de finanzas. Swift 6.4 + SwiftUI + GRDB (SQLite). Se compila e instala desde Linux con xtool, sin Mac. Commits y documentación en español. La interfaz está en inglés por defecto con español y francés como opciones (`Sources/CashFlow/Strings.swift`, clave = texto en inglés; `T("...")` en las vistas; `L10n` en el núcleo para meses y títulos de movimientos). Al agregar un texto nuevo hay que añadir su traducción es/fr.

Las notas operativas del teléfono del autor (ids de la base, respaldos, datos cargados) viven en `CLAUDE.local.md`, que no se versiona.

## Comandos

```bash
swift test                 # tests del núcleo (CashFlowCore) en Linux. Deben pasar antes de instalar.
xtool dev build            # compila para iOS (~10 s). Primer indicador de que todo está bien.
xtool dev                  # compila, firma e instala en el iPhone (desbloqueado y por USB).
```

- `sudo` y comandos interactivos (`xtool setup`) no corren desde la sesión de Claude; los ejecuta el usuario en su terminal.
- Si usbmuxd no ve el iPhone: `sudo systemctl restart usbmuxd`, desbloquear y reconectar.
- La firma con Apple ID gratuito caduca cada 7 días; reinstalar con `xtool dev` no borra datos.
- Versión: `CFBundleShortVersionString` en `Info.plist`. La `0.0.1` quedó etiquetada como beta oficial; desde el 2 de noviembre de 2026 se construye la **0.0.2** (en curso, sin fecha de cierre) y el número no sube con cada cambio. `CFBundleVersion` es el número de build y sí puede crecer.
- Ícono: `Icon.svg` → `Icon.png` con `rsvg-convert -w 1024 -h 1024 Icon.svg -o Icon.png`.
- Commits sin línea de coautor.

## Estructura

- `Sources/CashFlowCore`: modelos (`Models/Records.swift`), esquema y migraciones (`Database/AppDatabase.swift`), operaciones compuestas (`Database/Operations.swift`), respaldo JSON (`Database/Backup.swift`), cálculos en memoria (`Logic/Ledger.swift`), ciclos de tarjeta (`Logic/CardCycle.swift`), dinero y fechas (`Money.swift`, `Dates.swift`). Sin SwiftUI.
- `Sources/CashFlow`: la app. Cada archivo va envuelto en `#if canImport(SwiftUI)` para que `swift test` compile en Linux. `AppModel` es `@Observable @MainActor`, carga un `Snapshot` completo tras cada escritura.
- `Tests/CashFlowCoreTests`: Swift Testing. `Fixture` en `LedgerTests.swift` arma un escenario base.
- Todo saldo se calcula desde movimientos; nunca se guarda un saldo salvo `initialBalance`.
- Dinero en `Int64` unidad menor: COP en pesos, USD en centavos. `amountCOP` se guarda al registrar con la TRM del momento.
- Fechas como `DayDate` / `YearMonth` (texto ISO en SQLite). "Hoy" es en hora de Colombia (`AppCalendar`).

## Reglas del dominio

- **Mes en curso** se instancia solo al abrir la app (`startMonth`). Meses futuros se inician con botón y se pueden deshacer (`deleteMonth`, solo futuros).
- `startMonth` solo crea la proyección, las cuotas activas de `InstallmentPlan` y los ingresos pendientes de fuentes recurrentes (con el desglose plantilla `SourceDeduction`/`SourceBonus`). Aportes, consumibles, deudas y gastos necesarios se traen con el botón "Bring from <mes anterior>" de cada categoría (`copyFromPreviousMonth`) o con "Copy everything", sin duplicar lo que ya exista. Las tablas `ConsumableTemplate`/`CommitmentTemplate` y `fromTemplates: true` solo las usan los tests.
- Editar un mes futuro solo toca ese mes. Editar en el mes en curso actualiza el aporte sugerido del fondo y el desglose de la fuente recurrente.
- **Fondos** son bolsillos con propósito. `isSavings` cuenta como ahorro del mes. `resetsMonthly` solo cambia lo que se muestra. El saldo inicial solo se edita en `createdMonth`; después se usan movimientos manuales (`FundAdjustment`, con traslados entre fondos por `pairId`).
- **Consumibles** (en la interfaz se llaman **Bills** / Recibos / Factures desde el 2 de noviembre de 2026; el código conserva `Consumable`): gastos del mes que se pagan poco a poco. El total se aparta completo al proyectar (cuenta en `committed`). Un gasto o abono puede salir del apartado, ligado a un ítem (lo marca pagado) o suelto. `consumablesPending` (queda del apartado) y `consumablesUnpaid` (ítems sin pagar) son números distintos. Sin doble conteo en `spent`.
- **Compromisos** (deudas, incluidas cuotas de `InstallmentPlan`, y gastos necesarios) son plata apartada del ingreso, no gasto. Se pagan con un gasto o abono cuyo origen es el compromiso (`commitmentId` en `Expense`/`CardAllocation`); `Snapshot.paid(toward:)` dice cuánto va pagado y `commitmentsUnpaid` lo que falta. **Gastado** del mes = gastos sin tarjeta + gastos con tarjeta + ítems de consumibles pagados sin registro propio. Nunca sumar compromisos al gastado. `relinkCommitments` liga por nombre y luego por monto los movimientos del saldo libre con compromisos del mismo mes o del siguiente.
- **Tarjetas de crédito**: cada una con `cutDay`, `payDay` y un bolsillo de pago propio (`Fund.cardId`). Gasto de tarjeta → abonos (`CardAllocation`) desde fondo, saldo libre, consumibles o compromiso, que mueven plata al bolsillo. `CardPayment` saca del bolsillo y marca gastos pagados según lo que el usuario elija cubrir. Disponible = cupo − deuda sin pagar − cuotas por facturar de planes ligados. El "gastado" del mes suma gastos de tarjeta por fecha calendario, sin importar ciclos.
- **Cargos generados por la tarjeta** (`syncCardCharges`, en cada `reload` y en `startMonth`; idempotente): la cuota de manejo (`Card.feeAmount` desde `Card.feeSince`, `CardExpense.isFee`) y la cuota de cada `InstallmentPlan` ligado (`CardExpense.installmentPlanId`) se crean como gasto fechado en el corte y amortiguadas solas: la cuota de manejo desde el saldo libre, la cuota del plan desde su compromiso del mes. No se editan a mano (`isGenerated`); `savePlan(from:)` propaga a cuotas y compromisos sin pagar y `deletePlan` borra lo no pagado. Un plan sin tarjeta solo crea el compromiso mensual. Planes con intereses: `interestFree = false` + `installmentAmount`; el cupo se consume por capital (`capitalPerInstallment`).
- **Ciclos**: `Snapshot.cycleReport(card:cycle:)` da cargado, apartado, pagos y bolsillo tras el pago. Un pago pertenece al ciclo de `CardPayment.cycleEnd`; sin él, al ciclo cuyo corte va desde ese día hasta el día antes del siguiente corte. El detalle de tarjeta abre en el ciclo que cierra en el mes elegido (`model.month`, compartido por todas las pestañas). En Gastos, la sección de cada tarjeta se parte por ciclo cuando el mes abarca dos.
- **Devoluciones** (`CardRefund`, migración v14): una devolución del comercio baja el **neto** de un gasto de tarjeta (`CardExpenseStatus.netAmount = amountCOP − refunded`; `isCancelled` cuando cubre todo). Todo lo que suma gastos de tarjeta (gastado del mes, deuda, ciclo, conceptos, CSV) usa el neto vía `Snapshot.statuses(cardId:)`/`status(of:)`/`netAmount(of:)`. Los abonos nunca se borran por una devolución: lo que excede el neto es `surplus` ("Free to reuse") y `reuseSurplus(from:to:amount:)` mueve esos abonos a otra compra de la misma tarjeta partiendo el último si hace falta, conservando su origen; el bolsillo no cambia. UI: sección Refunds en `CardExpenseEditView` (agregar, cancelar toda la compra, reutilizar), `ReuseSurplusView` también desde la compra destino, fila "Surplus from refunds" en el detalle de tarjeta.
- **Proyección, ingresos de un mes real**: `copyIncomes(from:toScenario:)` (botón "Bring from <mes>" en la sección Income del escenario) reemplaza los ingresos del escenario por los del mes con neto > 0.
- **Pago de tarjeta** (`CardPaymentView`): el usuario escribe lo que cobró el banco (`statementAmount`), lo que pagó y lo que queda en el bolsillo; si difiere del calculado, `payCard(pocketBalanceAfter:)` crea un `FundAdjustment` "Pocket reconciliation".
- **Saldo real**: `setBalance(of:to:on:reason:)` deja un fondo o bolsillo en lo que el usuario dice. Está en el menú del detalle de fondo y tocando "Payment pocket" en la tarjeta. Al terminar un mes, `FinishMonthSheet` pide el saldo real de cada fondo y bolsillo antes de cerrar.
- **Terminar un mes** (`closeMonth`, botón "Finish" en Mes): disponible para meses pasados y para el mes del calendario desde dos días antes de que acabe (`Snapshot.canClose`). Marca pagados los consumibles, deja el apartado y el restante en cero con ajustes, y pone `Projection.closedAt`. No toca fondos. Con el mes del calendario terminado, `Snapshot.activeMonth(today:)` devuelve el siguiente y la app lo usa como mes en curso. `reopenMonth` deshace.
- **Mes al que pertenece un gasto** (`budgetMonth` en `Expense` y `CardExpense`; `month` = `budgetMonth ?? date.yearMonth`): una compra de fin de mes puede contar para el mes siguiente. Todo lo que resume por mes usa `month`; los abonos cuentan en el mes de su gasto (`Snapshot.allocations(in:)`). Fondos y ciclos de tarjeta usan la fecha real.
- **Saldos de fondos por mes**: `AppModel.fundReports` usa `fundsAsOf = max(hoy, último día del mes elegido)`; en meses pasados es el saldo de hoy. Los cuadres se fechan en `reconciliationDate = max(hoy, primer día del mes elegido)`.
- **Saldo libre** = ingresos − (aportes + consumibles + deudas + necesarios). **Restante** = saldo libre − gastos y abonos que salieron de él.
- **Modo discreto**: `MoneyFormat.hidden` (ajuste `ui.hideAmounts`, botón del ojo) enmascara todo monto; `MoneyText`/`MoneyRow` aceptan `percentOf:` y muestran porcentajes (ingresos sobre el total del mes, aportes y gastos sobre el ingreso, fondos sobre el total de fondos, deuda sobre el cupo). Al agregar una cifra nueva hay que darle base.
- **Piel iOS 26 (Liquid Glass)**, `Sources/CashFlow/Glass.swift`: mínimo `.iOS("26.0")`. Vidrio solo en la capa de navegación (barra de pestañas, `MonthStrip` como accesorio inferior, `FloatingAddButton`, hero, toast); el contenido es `List` nativa sobre `AuroraBackground` vía `.auroraList()`. Acento elegible (`AccentChoice`, pastel) que cambia tinte, hero y aurora. Detalles con `GlassStatCard` y transición zoom.
- Colores de estado solo semánticos (verde, naranja, rojo); la paleta categórica de `Palette` es para gráficas.
- Pestaña Mes: las secciones Income, Fund contributions, Bills, Debts y Necessary se pliegan tocando el título (chevron; estado en `@AppStorage("month.collapsed")`). Bajo Income va la sección **Distribution**: barra apilada (`ShareBars`) y filas con valor y % del ingreso por categoría y lo libre.
- Selector de mes: tocar el nombre abre `MonthJumpSheet`; mantener pulsado o tocar de nuevo la pestaña activa vuelve al mes en curso.
- Nada de nombres personales (empleadores, familiares, marcas de tarjetas) en textos de la interfaz, tests ni documentación versionada. Siempre "tarjeta de crédito", no "tarjeta".
- Acciones rápidas del ícono (`UIApplicationShortcutItems`, `QuickActions.swift`) y enlace `cashflow://add?amount=&reason=&card=|fund=&usd=1&date=&x-success=` (`DeepLink`) para registrar gastos desde Atajos. App Intents no es viable con xtool.
- **Proyección** (0.0.2, `Logic/Scenarios.swift`, `ProjectionView.swift`, migraciones v12 y v13): escenarios (`Scenario` + `ScenarioLine` por aporte/consumible/deuda/necesario; los ingresos son `Income` reales con `scenarioId`, con descuentos y bonos y el mismo `IncomeEditView`, y `Snapshot` los separa en `scenarioIncomes` para que no cuenten en ningún mes; toda consulta de `Income` por mes filtra `scenarioId IS NULL`) que se crean desde lo habitual del mes elegido (`createScenario(basedOn:)`: fuentes recurrentes o último ingreso, aporte sugerido o del mes base, consumibles y compromisos del mes base) y se editan sin tocar meses reales. `ScenarioSummary` da comprometido y libre; `applyScenario(to:)` reemplaza aportes, consumibles y compromisos sin plan de un mes (en curso o futuro). Entrada: pestaña Mes → "Projection".
- **Bloqueo opcional** (`AppLock.swift`, LocalAuthentication, ajuste `ui.lock`): Face ID o código al abrir y al volver del fondo.
- Recordatorios locales (`Reminders.swift`) dos días antes de corte y pago. Widget en `Attic/`: no viable con xtool en cuenta gratuita (sin App Groups).
- Nunca borrar filas con `sqlite3` directo sin limpiar hijos: la CLI no aplica claves foráneas. Nunca perder datos del teléfono: migraciones solo agregan; hay test de migración desde v1.

## Base de datos del teléfono

- Bundle ID instalado por xtool: `<TeamID>.com.diegorincon.cashflow`. Con ese ID funciona `afcclient --container`.
- Ruta en el contenedor: `/Library/Application Support/CashFlow/cashflow.sqlite`.
- Bajar: `afcclient --container <id> get "<ruta>" local.sqlite`. Subir: `mv` el viejo a un nombre de respaldo y luego `put`. Solo con la app cerrada; reinstalar con `xtool dev` la cierra. Siempre dejar copia en `.backups/` (ignorado).
