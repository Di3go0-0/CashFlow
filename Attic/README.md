# Attic

Código que funciona pero no se puede usar todavía.

## CashFlowWidget

Widget de pantalla de inicio que lee `widget.json` del App Group. Compila, se firma e instala con xtool, pero xtool no
aprovisiona App Groups en cuentas gratuitas (`DeveloperServicesCapability.swift`: `AppGroupEntitlement … isFree: false`)
y no pasa entitlements a las extensiones (`SignerImpl.swift`, issue #131). Sin eso el contenedor compartido no existe
y el widget nunca ve datos.

Para reactivarlo cuando xtool lo soporte: devolver `Sources/CashFlowWidget`, el producto y target en `Package.swift`
(con `-Xlinker -u -Xlinker _main` y `-headerpad_max_install_names`), y en `xtool.yml` `entitlementsPath` más la sección
`extensions` con `CashFlowWidget-Info.plist`. La app ya escribe el JSON (`AppModel.publishWidgetSnapshot`).
