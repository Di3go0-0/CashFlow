# CashFlow — Diseño

App iOS personal de finanzas por bolsillos. Se instala en el iPhone desde Linux con xtool.

## Stack

| Pieza | Decisión |
|---|---|
| Lenguaje / UI | Swift 6.4, SwiftUI, `@Observable`, diseño iOS 26 (Liquid Glass) |
| Proyecto | Paquete SwiftPM, build con `xtool dev` |
| Persistencia | SQLite local vía GRDB.swift (SwiftData no funciona con xtool) |
| Dinero | `Int64` en unidad menor + código de moneda. COP sin decimales en la interfaz |
| TRM USD→COP | Se consulta a una API pública al registrar el gasto y se guarda en el movimiento. Editable a mano |
| Respaldo | Exportar / importar JSON a la app Archivos |

## Modelo de datos

Todo saldo se calcula desde movimientos. Nada de saldos guardados a mano salvo el saldo inicial de un fondo.

- **IncomeSource / Income**: fuentes de ingreso recurrentes o puntuales; cada ingreso trae bruto o neto, descuentos (porcentaje o fijo) y bonos.
- **Fund**: bolsillo con propósito. Aporte mensual sugerido, bandera de ahorro, bandera de "se vacía cada mes", saldo inicial. Un fondo con `cardId` es el bolsillo de pago de esa tarjeta.
- **FundAdjustment**: movimiento manual de un fondo, incluidos traslados entre dos fondos y cuadres de saldo real.
- **Consumable**: gasto fijo del mes que se paga poco a poco. El total se aparta completo al proyectar.
- **Projection**: el plan del mes: aportes, deudas, gastos necesarios y consumibles. Puede terminarse (`closedAt`) y entonces el mes siguiente pasa a ser el mes en curso.
- **Commitment**: deuda o gasto necesario del mes. Es plata apartada, no gasto, hasta que un gasto o abono lo paga.
- **InstallmentPlan**: compra a cuotas, con o sin tarjeta, sin o con intereses. Genera un compromiso por mes y, si va a una tarjeta, un cargo en cada corte que ocupa cupo hasta facturarse.
- **Card / CardExpense / CardAllocation / CardPayment**: tarjeta de crédito con corte y fecha de pago; gastos en pesos o dólares; abonos que mueven plata al bolsillo de pago desde un fondo, el saldo libre, los consumibles o un compromiso; pagos que salen del bolsillo y marcan gastos como pagados, con lo que cobró el banco y el saldo real que quedó.
- **Expense**: gasto sin tarjeta, con origen (fondo, consumible, compromiso o saldo libre) y mes al que pertenece, que puede ser distinto al de la fecha.

## Pantallas

1. **Resumen**: libre para gastar y cuánto por día, a dónde va el ingreso, últimos seis meses, fondos y tarjetas. Botón del ojo para ver solo porcentajes.
2. **Mes**: ingresos, aportes, consumibles, deudas y gastos necesarios; traer del mes anterior por categoría o todo; terminar el mes con cuadre de saldos reales.
3. **Fondos**: saldo, flujo por contraparte, movimientos manuales, saldo real.
4. **Tarjetas de crédito**: ciclos, deuda y cupo, bolsillo de pago, balance por ciclo y pagos.
5. **Gastos**: con y sin tarjeta, búsqueda, conceptos, CSV.
6. **Ajustes**: acento, idioma, Face ID, recordatorios, TRM, catálogos, respaldo.

## Historial

- Octubre de 2026: primera versión funcional, reglas de dominio decididas sobre la marcha, meses históricos cargados y cuadrados contra el banco.
- 31 de octubre de 2026: cuotas y cuota de manejo automáticas, balance por ciclo, mes compartido entre pestañas, modo discreto, piel iOS 26.
- 1 de noviembre de 2026: beta oficial 0.0.1 (`v0.0.1`).
