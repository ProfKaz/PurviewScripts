# Primera prueba: creación del sitio piloto

Esta fase crea un sitio de comunicación y puede aprovisionar una base vacía con `-DeployFoundation`. No instala el portal SPFx ni publica perfiles, eventos o credenciales. El instalador integral sigue pendiente. No reutiliza ni cambia automáticamente un sitio existente.

## Datos no secretos necesarios

- URL del centro de administración SharePoint del tenant destino.
- URL propuesta del sitio y UPN de su propietario.
- Tenant ID o dominio verificado y Client ID de una aplicación Entra aprobada para login interactivo de PnP. Client ID no es un secreto.

El usuario inicia sesión y completa MFA directamente en Microsoft. No pasar contraseñas, tokens ni secretos al script. No se usa `PersistLogin`. Para un sitio de comunicación, PnP documenta permiso delegado SharePoint `AllSites.FullControl`; la cuenta debe tener rol suficiente para crear sitios. Esta identidad de instalación es distinta de la identidad de lectura de perfiles de los agentes.

Si no existe aplicación interactiva, preparar un registro dedicado con permisos explícitos y revisarlo con el administrador. No usar los permisos predeterminados amplios de `Register-PnPEntraIDAppForInteractiveLogin`. El registro y consentimiento se realizan como un paso de autenticación separado; no los concede este script.

## Registrar la aplicación dedicada (una vez por tenant)

`deployment/Register-ScannerPortalSetupApp.ps1` prepara el registro **Kaz Demos Scanner Portal - Setup**, single-tenant, con permisos delegados explícitos `User.Read` (Graph) y `AllSites.FullControl` (SharePoint). No solicita permisos de aplicación ni crea secretos. Incorpora el logo del repositorio si está disponible.

```powershell
# Revisar el plan sin iniciar sesión:
./ScannerPortal/deployment/Register-ScannerPortalSetupApp.ps1 -Tenant contoso.onmicrosoft.com

# Registrar e iniciar sesión en Microsoft:
./ScannerPortal/deployment/Register-ScannerPortalSetupApp.ps1 `
  -Tenant contoso.onmicrosoft.com -Mode Apply -DeviceLogin
```

La identidad usada para el registro necesita permiso de crear aplicaciones en Entra; el consentimiento administrativo depende de los roles/políticas del tenant. La sesión de registro del cmdlet de PnP puede solicitar permisos administrativos necesarios para crear la aplicación; distinguirlos de los permisos del cliente que se está registrando. Revisar el consentimiento mostrado por Microsoft. No se otorgan privilegios al agente del scanner.

Conservar el **Client ID público** que devuelve el registro para la siguiente fase. `Apply` registra una nueva aplicación; no es un upsert. Si hay error o timeout, revisar primero las aplicaciones de Entra y recuperar el ID existente antes de repetir, para evitar duplicados. No publicar tokens ni logs completos de autenticación en GitHub.

## Plan offline

```powershell
./ScannerPortal/deployment/New-ScannerPortalPilot.ps1 `
  -AdminUrl https://contoso-admin.sharepoint.com `
  -SiteUrl https://contoso.sharepoint.com/sites/ScannerPortalPilot `
  -Owner admin@contoso.onmicrosoft.com
```

`-Mode Apply -WhatIf` también devuelve el plan sin iniciar sesión ni conectarse al tenant.

## Crear sitio

Con PowerShell 7.4+ y PnP.PowerShell 3.2.0 o superior:

```powershell
./ScannerPortal/deployment/New-ScannerPortalPilot.ps1 `
  -AdminUrl https://contoso-admin.sharepoint.com `
  -SiteUrl https://contoso.sharepoint.com/sites/ScannerPortalPilot `
  -Owner admin@contoso.onmicrosoft.com `
  -Tenant contoso.onmicrosoft.com `
  -ClientId 00000000-0000-0000-0000-000000000001 `
  -Mode Apply -DeployFoundation
```

El Client ID del ejemplo es ficticio. El script usa login interactivo; `-LoginMethod DeviceLogin` permite completar el login mediante el código que Microsoft muestre, si la política del tenant lo permite. Puede solicitar sesión para administración y para el sitio. Nunca copiar códigos MFA al chat.

El script comprueba que ambas URLs pertenecen al mismo tenant comercial y que el destino es `/sites/<alias>`. Consulta existencia antes de crear; un fallo de consulta detiene la operación. Si existe, devuelve `AlreadyExistsNeedsReview` y no cambia nada. Tras crear, deshabilita compartir externamente y devuelve grupos y asignaciones de roles para su revisión. No afirma que el sitio sea privado solo por haberlo creado: políticas/plantillas del tenant pueden conceder acceso adicional y los administradores conservan acceso.

Si falla después de crear, conservar la URL y revisar el estado; no elimina el sitio ni borra recursos como compensación automática. Una segunda ejecución detecta la existencia y pide revisión operativa, sin recrear ni alterar el sitio.

## Base nativa del piloto

`-DeployFoundation` llama a `Install-ScannerPortalFoundation.ps1` con las conexiones activas después de crear el sitio. Comprueba uso compartido externo deshabilitado, sitio/identidad esperados y que no haya asignaciones o administradores configurados fuera del propietario. Un hallazgo bloquea el aprovisionamiento. Los administradores del tenant conservan sus facultades administrativas.

La base crea dos bibliotecas vacías ocultas, sin indexación de búsqueda y con permisos únicos, seis listas vacías con columnas indexadas y una página moderna nativa con «Powered by Kaz Demos». Todavía no hay telemetría, administración de perfiles desde la interfaz ni paquete SPFx. No se conceden permisos a agentes. La lista de recursos se lee de `deployment/solution-manifest.json`; las columnas iniciales solo cubren los índices y no equivalen a los contratos completos de ingesta.

Para reintentar solo la base después de un fallo parcial, usar `Install-ScannerPortalFoundation.ps1 -Mode Apply -SiteUrl <url> -Owner <upn> -AdminConnection $admin -SiteConnection $site` con conexiones PnP explícitas y aprobadas al sitio piloto. Si no se pasan conexiones, el modo predeterminado devuelve el plan. No se eliminan recursos; conservar el sitio para revisar errores.

## Evidencia de pruebas

Ejecutar `tests/Test-PilotPlan.ps1` sin conexión comprueba plan, WhatIf y rechazo de URLs/propietarios inválidos. Estas pruebas no validan autenticación, creación, permisos efectivos ni idempotencia online. Registrar esos resultados después de ejecutar contra el tenant piloto. Guardar evidencia del tenant fuera del repositorio público.

Siguiente fase: revisar membresías/asignaciones, aprovisionar bibliotecas restringidas y listas indexadas, probar acceso denegado con otra identidad y después desplegar el paquete SPFx cuando esté implementado.

Referencias: [Connect-PnPOnline](https://pnp.github.io/powershell/cmdlets/Connect-PnPOnline.html), [New-PnPSite](https://pnp.github.io/powershell/cmdlets/New-PnPSite.html), [registro interactivo](https://pnp.github.io/powershell/cmdlets/Register-PnPEntraIDAppForInteractiveLogin.html).
