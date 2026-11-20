# Portal y endpoints administrados — piloto 1.0

## Alcance implementado

El instalador único 1.3.0 descarga el paquete completo, con etapas ControlPlane y ManagedEndpoint independientes del SDK. Reutiliza el sitio/Foundation existentes. El administrador prepara una app dedicada, aprueba certificados públicos y publica/asigna perfiles. El endpoint PS5.1 consulta la asignación, valida y materializa los cinco JSON del scanner, ejecuta ciclos limitados, conserva informes y verifica cargas mediante descarga y SHA-256. No requiere elevación local ni distribuye secretos o claves privadas. Los módulos Graph/PnP solo se instalan en el equipo administrativo; el endpoint usa PowerShell/.NET integrados.

La administración de perfiles se realiza mediante scripts y bibliotecas SharePoint en esta entrega; todavía no hay editor SPFx. La interfaz de reportes, el procesador central de aceptación/proyecciones, la retención automática y la clasificación/etiquetado SDK integrados en este runner siguen pendientes. No se presentan como implementados por disponer ya del transporte. El laboratorio SDK anterior permanece independiente.

## Identidad y límite de confianza

- App única dedicada: Kaz Demos ScannerPortal Endpoints. No modifica ni reutiliza la app MIP ni la app administrativa.
- Permiso de aplicación Graph Lists.SelectedOperations.Selected; grant read a ScannerPortalConfig y write a ScannerPortalLanding. No Sites.ReadWrite.All, secretos de cliente ni permisos administrativos en endpoints.
- Cada estación/cuenta genera un certificado RSA CurrentUser no exportable y un GUID de registro. Envía solo el DER público en una solicitud que un operador aprueba. El endpoint confirma posesión de la clave cuando obtiene el token. La solicitud y el nombre del equipo no son atestación del dispositivo.
- Todos los certificados de la misma app tienen los mismos permisos: pueden leer todos los perfiles y modificar la biblioteca de entrada, incluidos informes de otros registros. El parámetro AllowSharedIngress exige reconocerlo durante Initialize. Las carpetas separan organización de datos, no autorización por equipo. No colocar datos confidenciales de otros grupos ni evidencia final en esa biblioteca bajo este modelo.
- El piloto valida este transporte compartido. No equivale a una solución contra modificación por endpoints comprometidos. Una biblioteca de evidencia aceptada necesita un procesador/identidad central y no recibe grant del endpoint. No hay recibo Accepted ni custodia central implementados todavía.
- La renovación, revocación individual de claves y capacidad de credenciales por aplicación se deben ensayar antes de despliegues masivos. No se promete un certificado por estación ilimitadamente en una única app. Las operaciones administrativas de credenciales deben serializarse desde el mismo directorio de estado; el bloqueo no es distribuido entre equipos administradores.

## Preparación y pruebas secuenciales

Usar Windows PowerShell 5.1 x64 normal en C:\Deploy\Endpoint MIP Scanner. El instalador abre su runtime PS7 portátil para administración, sin solicitar administrador local. El registro inicial sí requiere una cuenta Microsoft 365 autorizada para registrar aplicaciones, consentir permisos y conceder acceso en el sitio. Deben existir las bibliotecas Foundation con acceso restringido; el script se detiene ante herencia o accesos sustantivos ajenos a administradores del sitio. No elimina permisos existentes para forzar el resultado.

### 1. Actualizar e inicializar una sola vez

```powershell
Set-Location 'C:\Deploy\Endpoint MIP Scanner'
.\Install-EndpointMIPScanner.ps1 -Ref feat/scannerportal-managed-endpoints -Stage Download
.\Install-EndpointMIPScanner.ps1 -Ref feat/scannerportal-managed-endpoints -Stage ControlPlane `
    -ControlPlaneAction Initialize -AllowSharedIngress `
    -TenantId 'd88f1561-bdab-46f0-b8ba-bfca21e1b5c4' `
    -SiteUrl 'https://mhcybersecuritydemos.sharepoint.com/sites/ScannerPortalPilot'
```

Si falta .endpoint-install/portal-app.json, agregar PortalClientId con el ID de la app administrativa existente. No usar el Client ID de MIP. Initialize conserva el ID de la nueva app en .endpoint-install/controlplane/controlplane.json y genera endpoint-bootstrap.json. Una app homónima sin estado guardado requiere ControlPlaneClientId explícito para adoptarla; nunca se selecciona arbitrariamente por nombre. El bootstrap contiene exclusivamente IDs y URL públicos. No distribuir el directorio administrativo completo.

### 2. Enrolar un endpoint sin elevación

Distribuir el instalador único y el bootstrap generado. La instalación necesita acceso a GitHub para descargar el paquete fijado a un commit. No supone que Graph permita un enrolamiento anónimo.

```powershell
$bootstrap = Join-Path $PWD '.endpoint-install\controlplane\endpoint-bootstrap.json'
.\Install-EndpointMIPScanner.ps1 -Ref feat/scannerportal-managed-endpoints `
    -Stage ManagedEndpoint -BootstrapPath $bootstrap
```

El resultado magenta indica RequestPath y RegistrationId. En otra estación copiar únicamente endpoint-bootstrap.json a una ubicación conocida y usar esa ruta. La solicitud queda en %LOCALAPPDATA%\EndpointMIPScanner\ManagedEndpoint\enrollment-request.json; se devuelve al operador por un canal controlado. El certificado privado permanece en el perfil de la cuenta que ejecutará la tarea.

### 3. Aprobar la solicitud desde administración

```powershell
.\Install-EndpointMIPScanner.ps1 -Ref feat/scannerportal-managed-endpoints -Stage ControlPlane `
    -ControlPlaneAction Approve `
    -EnrollmentRequest "$env:LOCALAPPDATA\EndpointMIPScanner\ManagedEndpoint\enrollment-request.json" `
    -TenantId 'd88f1561-bdab-46f0-b8ba-bfca21e1b5c4' `
    -SiteUrl 'https://mhcybersecuritydemos.sharepoint.com/sites/ScannerPortalPilot'
```

En el administrador usar la ruta de la solicitud recibida, no la de su propio perfil por accidente. Verificar solicitante/huella mediante el canal de enrolamiento. La aprobación agrega el certificado público sin borrar claves existentes; si Graph no devuelve las claves que se deben preservar, se detiene. Repetir la misma aprobación no agrega otra clave. No otorgar a endpoints permisos para agregar sus propios certificados.

### 4. Publicar y asignar un perfil

Copiar ScannerPortal/config/managed-profile.example.json fuera de Config, por ejemplo a .endpoint-install/pilot-profile.json. Ajustar roots a una carpeta pequeña que exista y que tenga un TXT/CSV sintético con PILOT-123456. Actualizar expiresUtc a una fecha UTC futura. No empezar con C:\ completo. Usar el RegistrationId del paso 2.

```powershell
$registrationId = Read-Host 'RegistrationId del endpoint aprobado'
.\Install-EndpointMIPScanner.ps1 -Ref feat/scannerportal-managed-endpoints -Stage ControlPlane `
    -ControlPlaneAction Publish -RegistrationId $registrationId `
    -ProfilePath '.\.endpoint-install\pilot-profile.json' `
    -TenantId 'd88f1561-bdab-46f0-b8ba-bfca21e1b5c4' `
    -SiteUrl 'https://mhcybersecuritydemos.sharepoint.com/sites/ScannerPortalPilot'
```

Un perfil publicado usa profiles/profileId/version/sha256.json. Cambiar su contenido requiere otra versión; asignar una versión anterior permite rollback. El puntero assignments/registrationId.json usa ETag al actualizarse. Se valida mediante PS5.1 y los validadores reales del scanner antes de publicar. Los reintentos no reemplazan perfiles con contenido diferente en la misma versión.

### 5. Validar sincronización y entrega, una operación por vez

```powershell
.\ScannerPortal\Invoke-ScannerPortalEndpoint.ps1 -SyncOnly
.\ScannerPortal\Invoke-ScannerPortalEndpoint.ps1
.\ScannerPortal\Invoke-ScannerPortalEndpoint.ps1
```

Comprobar ProfileSource=Portal, versión esperada y DeliveryState=UploadedVerified en cada ciclo. La segunda pasada debe reutilizar la auditoría TXT/CSV si el archivo y las reglas siguen iguales. Consultar last-status.json y los registros locales. Verificar desde una identidad administrativa la carpeta ScannerPortalLanding/devices/registrationId/batches/runId. El manifiesto se sube al final. UploadedVerified significa descarga/hash comparados por el endpoint, no aceptación independiente de un procesador central.

Cambiar extensiones/exclusiones/reglas en otra versión y volver a publicar para el mismo registro. Paused=true detiene nuevos escaneos en la siguiente consulta; permite drenar cargas pendientes. Modificar idleSeconds no reinicia el índice. Cambiar el ámbito/reglas crea estado incremental separado, conserva el anterior y puede exigir una primera pasada del nuevo ámbito. El perfil solo contiene datos, nunca comandos ejecutables.

### 6. Instalar tarea solo después de validar

```powershell
.\Install-EndpointMIPScanner.ps1 -Ref feat/scannerportal-managed-endpoints `
    -Stage ManagedEndpoint -BootstrapPath $bootstrap -RegisterTask
```

La instalación comprueba token y perfil antes de registrar. Crea EndpointMIPScanner-RegistrationId, RunLevel Limited y LogonType Interactive, con disparador al iniciar sesión y runner continuo. No inicia la tarea automáticamente; para iniciar la prueba usar Start-ScheduledTask -TaskName con el nombre devuelto. Corre con la misma cuenta y perfil, mientras el usuario tenga sesión. No funciona como servicio SYSTEM ni promete operar después de cerrar sesión. Al volver a iniciar sesión arranca de nuevo. Un servicio fuera de sesión requerirá otro diseño de despliegue/identidad administrado por TI.

## Recuperación, límites y trazabilidad

- Un escritor por registro. Estado y configuración no se escriben directamente sobre una generación activa incompleta.
- Se conserva última configuración válida ante fallos transitorios de descarga/validación; una caché expirada o corrupta impide escanear. 400/401/403 y 404 (asignación/perfil retirado) no se presentan como operación offline válida.
- Una carga incompleta permanece pendiente. Mismo runId conserva el mismo batchId; un contenido remoto distinto con ese ID genera conflicto. No elimina el lote local.
- Si el proceso cae después de escribir el log y antes de sellar el lote, el contexto del ciclo permite reconstruirlo al reiniciar. Un log sin resumen se marca PartialInterruptedRun y conserva sus registros originales, incluidos registros incompletos. No se interpreta como cobertura total.
- Formato ScannerPortal.InventoryRun/1 con records.jsonl, summary.json y manifest.json. Es distinto del lote consolidado de descubrimiento nativo anterior: las colas y lotes antiguos no se modifican ni se suben automáticamente con un contrato equivocado.
- Límite piloto de 64 MiB por archivo de informe y cuota local de 512 MiB del directorio administrado. Al alcanzar cuota se detiene el escaneo; no borra evidencias. Retención, compactación, subida por segmentos y limpieza de generaciones quedan posteriores. El estado incremental configurado fuera del directorio administrado no se contabiliza en esa cuota.
- stateDirectory es una base; se añade registrationId y hash del ámbito. El runner excluye automáticamente su instalación y su directorio de datos para evitar reingerir sus informes.
- El modo administrado actual audita reglas locales sobre TXT/CSV e inventaría las demás extensiones. No ejecuta clasificación oficial de todos los SIT ni aplica etiquetas. No se aceptan campos de etiquetado/ejecución desconocidos que aparenten habilitar esas capacidades.
- El cliente consulta cada idleSeconds después de un ciclo acotado por maxSeconds. Es pull con consistencia eventual; no hay push ni efecto inmediato sobre un equipo desconectado.

## Pruebas y pendientes

Test-ManagedEndpoint cubre certificado CurrentUser público/idempotente real, validación de perfiles, Unicode, digest/caché, escaneo incremental real, cambio de ámbito, desconexión después de escribir, reintento y hash remoto inválido. Graph se simula. Test-ScannerPortalProfile valida perfiles sin escanear. No registrar tareas ni probar permisos reales se sustituye por estas pruebas: ambos requieren el equipo/tenant del piloto.

Criterios remotos antes de ampliar: app puede leer Config y escribir Landing; no puede escribir Config ni acceder a una biblioteca ajena; cuenta sin permisos no ve los datos por acceso normal; probar certificado revocado, reinicio, tarea bajo cuenta estándar y actualización/rollback de perfil. El acceso compartido a Landing es conocido, no una prueba negativa esperada entre emisores.

Referencias: [grants de lista](https://learn.microsoft.com/en-us/graph/api/list-post-permissions?view=graph-rest-1.0), [permisos seleccionados](https://learn.microsoft.com/en-us/graph/permissions-selected-overview), [certificados públicos en aplicaciones](https://learn.microsoft.com/en-us/graph/applications-how-to-add-certificate).

Validación ejecutada el 20 de noviembre de 2026: Test-ManagedEndpoint en Windows PowerShell 5.1 sin elevación (certificado local y scanner reales; Graph simulado); restauración de caché desde un proceso PS5.1 nuevo; Test-ControlPlane en PS7.6 con Graph/PnP simulados y validador PS5.1 real; Test-Incremental, Test-SuiteLayout y análisis sintáctico. No se ejecutó registro de tarea, aprobación real en Entra ni operaciones de SharePoint del tenant.
