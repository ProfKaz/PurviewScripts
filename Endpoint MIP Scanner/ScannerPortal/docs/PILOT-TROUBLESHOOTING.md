# Diagnóstico reproducible del piloto

Ejecutar solo la sección correspondiente al síntoma. Las consultas de este documento son de lectura en el tenant. Las descargas crean archivos locales. Las pruebas de laboratorio generan sus propios datos. Registrar equipo, versión, UTC, RunId, registro y perfil antes de intervenir. Compartir contadores y códigos; mantener logs crudos, rutas personales, valores sensibles, tokens y claves privadas dentro del entorno autorizado.

## Instalación, dependencias y catálogo

Endpoint: Windows PowerShell 5.1 x64. EndpointInstall se ejecuta elevado para escribir en Program Files. EndpointConfigure y el escaneo se ejecutan en la sesión normal de la cuenta enrolada. Administración SPO: PowerShell 7.4+ y PnP.PowerShell 3.2.0; el receptor requiere instalación para todos los usuarios. Para instalar, aprobar y asignar, seguir [despliegue del agente](MANAGED-ENDPOINTS.md) y [receptor](RECEIVER-HOST.md). Usar el instalador único y un commit explícito, especialmente al cambiar de rama.

~~~powershell
$PSVersionTable | Select-Object PSVersion,PSEdition
[Environment]::Is64BitProcess
Get-Module -ListAvailable PnP.PowerShell | Select-Object Version,ModuleBase
Get-Module PnP.PowerShell | Select-Object Version,Path
Get-Command Get-FileStatus,Set-FileLabel -ErrorAction SilentlyContinue |
    Select-Object Name,Source,Version
~~~

Si falta WinPSCompatibility.ps1 o ConvertTo-WinPSHex, recuperar la instalación con el bootstrap de la suite. Si falla la extracción del SDK y el instalador no devuelve DotNetPath/LabAssembly, resolver esa etapa antes de interpretar el catálogo; un ExitCode nulo y una lista de etiquetas vacía no son un ensayo de política ejecutado. Véanse [autodiagnóstico y autenticación SDK](../../labs/MipSdkAudit/README.md) y [prueba M6 y correlación](../../labs/MipSdkAudit/ACTIVITY-PILOT.md). Ante NetworkException en loadPolicy registrar la etapa y comparar consulta de política, descubrimiento y lectura de etiqueta bajo el mismo usuario.

Para el portal, en PS7 emplear la app administrativa y una cuenta autorizada. Estas constantes identifican el piloto; sustituir todas en otro tenant.

~~~powershell
$site = 'https://mhcybersecuritydemos.sharepoint.com/sites/ScannerPortalPilot'
$tenant = 'd88f1561-bdab-46f0-b8ba-bfca21e1b5c4'
$setup = 'f95bae44-e6ee-4673-a5e2-8fc1fb08cd64'
Import-Module PnP.PowerShell -RequiredVersion 3.2.0
$conn = Connect-PnPOnline -Url $site -Tenant $tenant -ClientId $setup -Interactive -ReturnConnection
Get-PnPApp -Scope Site -Connection $conn |
    Select-Object Title,Id,AppCatalogVersion,InstalledVersion,Deployed
~~~

TenantAppCatalog nulo: comprobar inicialización del catálogo del tenant antes de habilitar el de la colección. ErrorMessage = Success por sí solo no indica fallo. Si ya existe el .sppkg, comprobar versión instalada y hash con [el instalador versionado](../deployment/Install-ScannerPortalReport.ps1) antes de intentar reemplazarlo. Si Batch detail muestra siempre 2293 archivos, comprobar URL y pie de página: el selector está desde 0.13.1. Recargar, abrir una aceptación desde Run audit y comparar el RunId del encabezado. Para el despliegue validado se espera 0.13.2.0 en catálogo y 0.13.2 al pie.

## Tarea del agente y estado fresco

En PS5.1 normal en el endpoint, leer de nuevo la tarea y el JSON en cada consulta. Comparar el inicio UTC del ciclo contra el inicio real de la tarea. TaskStarted=false en la salida de registro indica que ese comando no la arrancó. El arranque normal requiere sesión abierta.

~~~powershell
$base = Join-Path $env:LOCALAPPDATA 'EndpointMIPScanner\ManagedEndpoint'
$reg = Get-Content (Join-Path $base 'registration.json') -Raw | ConvertFrom-Json
$name = 'EndpointMIPScanner-' + $reg.registrationId
$task = Get-ScheduledTask -TaskName $name
$info = Get-ScheduledTaskInfo -TaskName $name
$status = Get-Content (Join-Path $base 'last-status.json') -Raw | ConvertFrom-Json
[pscustomobject]@{
    CheckedUtc=[datetime]::UtcNow; Registration=$reg.registrationId; State=$task.State
    User=$task.Principal.UserId; RunLevel=$task.Principal.RunLevel
    LastStart=$info.LastRunTime; NextStart=$info.NextRunTime
    LastResult=('0x{0:X8}' -f $info.LastTaskResult)
    RestartCount=$task.Settings.RestartCount; Instances=$task.Settings.MultipleInstances
    Intervals=@($task.Triggers | ForEach-Object { $_.Repetition.Interval })
    Cycle=$status
} | ConvertTo-Json -Depth 6
Get-ChildItem -LiteralPath $base -Filter '*error*.log' | Select-Object Name,LastWriteTimeUtc
~~~

Running/0x00041301 es normal para el proceso continuo. Con PT15M e IgnoreNew se ofrece otro arranque si la tarea queda lista y la cuenta tiene sesión. Validar con un RunId posterior y UploadedVerified sin arranque manual. Si el identificador no cambia, releer last-status.json y comprobar que el perfil no esté pausado. Si cambia a Cache con fallo transitorio, revisar la última configuración válida y su expiración. Si 401/403 persiste, validar registro, asignación y certificado CurrentUser bajo esa misma cuenta. Evitar reiniciar repetidamente una tarea durante la investigación.

### Correlación de 0xC0000409

Ejecutar después del bloque anterior. Acotar la ventana a la hora real del incidente. Si el log operacional estaba deshabilitado o la cuenta carece de acceso, registrar esa limitación. Los reintentos configurados no demuestran que se hayan ejecutado.

~~~powershell
$since = (Get-Date).AddDays(-2)
function Get-PilotEventData($event) {
    $data = @{}
    foreach ($field in ([xml]$event.ToXml()).Event.EventData.Data) {
        if ($field.Name) { $data[[string]$field.Name] = $field.InnerText }
    }
    $data
}
Get-WinEvent -FilterHashtable @{LogName='Application';ProviderName='Application Error';Id=1000;StartTime=$since} |
    ForEach-Object {
        $f = Get-PilotEventData $_
        if ($f.AppName -in 'powershell.exe','ScannerTaskHost.exe','MSIPExecutionHost.exe') {
            [pscustomobject]@{Utc=$_.TimeCreated.ToUniversalTime();Process=$f.AppName;Module=$f.ModuleName;Code=$f.ExceptionCode}
        }
    }
$log = 'Microsoft-Windows-TaskScheduler/Operational'
Get-WinEvent -ListLog $log | Select-Object LogName,IsEnabled
Get-WinEvent -FilterHashtable @{LogName=$log;Id=100,101,102,111,200,201,202,203;StartTime=$since} |
    ForEach-Object {
        $f = Get-PilotEventData $_
        if ($f.TaskName -eq ($task.TaskPath+$task.TaskName)) {
            [pscustomobject]@{Utc=$_.TimeCreated.ToUniversalTime();Id=$_.Id;Result=$f.ResultCode;Instance=$f.InstanceId}
        }
    }
~~~

El código decimal 3221226505 equivale a 0xC0000409. El host propaga el código del hijo. Un módulo desconocido y ese código no identifican el componente causal. Para los resultados concretos de cada máquina consultar la [cronología](PILOT-EVIDENCE.md).

## Cero archivos, hallazgos desconocidos y cola

En la misma consola, usar el RunId del lote afectado. En el piloto, el lote 420 de Sebastián informó cero archivos y un error. Una generación cerrada puede tener errores. Esta consulta muestra la ruta solo al operador local.

~~~powershell
$run = '166e0207357844ed863f2b06d6e5775f'
foreach ($stage in 'Pending','Uploaded') {
    $queue = Join-Path $base "outbox\$stage"
    if (Test-Path -LiteralPath $queue) {
        Get-ChildItem -LiteralPath $queue -Directory | Measure-Object | Select-Object @{n='Queue';e={$stage}},Count
        $records = Join-Path $queue "$run\records.jsonl"
        if (Test-Path -LiteralPath $records) {
            Get-Content -LiteralPath $records -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json } |
                Where-Object event -eq 'error' | Select-Object operation,path,message
        }
    }
}
~~~

Revisar raíz real (también Documentos redirigido a OneDrive), exclusiones y permisos de la cuenta en Agent management. Publicar una versión y comprobar heartbeat antes de interpretar el siguiente lote. Unknown puede deberse a error o ausencia de respuesta del motor de descubrimiento. Leer etiqueta y detectar SIT son operaciones independientes. Audit content controla reglas locales. Revisar SIT seleccionado, resultado por formato y estado del cliente antes de interpretar cero coincidencias.

Si aparece «Active journal scope changed», comparar versión, registro, perfil y alcance; 1.4.3 incorporó compatibilidad con las exclusiones del journal anterior. La recuperación exitosa conserva generation y muestra resumedDirectories positivo. Preservar journal, logs y cola; un nuevo rescan produce otra generación y no recupera evidencia de la anterior.

## Receptor, permisos y aceptación

En el host administrativo, consultar la tarea específica del sitio y su status.json. Para permisos protegidos en Program Files usar la consola administrativa. Un agente Running y un receptor detenido son fallos distintos.

~~~powershell
Get-ScheduledTask -TaskName 'ScannerPortal-Receiver-*' | Select-Object TaskName,State
$receiverState = Join-Path $env:ProgramFiles 'Endpoint MIP Scanner Receiver\52AC56730C6EF3B9\state\status.json'
Get-Content -LiteralPath $receiverState -Raw | ConvertFrom-Json | ConvertTo-Json -Depth 6
~~~

Esperado: SID S-1-5-19 y una ejecución reciente Completed. Discovered=0, Pending=0 y cursor estable puede ser normal si no llegaron lotes. Con backlog revisar Pending, cursor y último error. Comparar RunId en outbox/Uploaded, biblioteca Landing, lista de aceptación y Run audit, en ese orden. El recibo local no acredita que el reporte se haya materializado. Investigar disponibilidad para todos los usuarios de PnP 3.2.0 si solo el usuario interactivo puede cargarlo. Mantener un único receptor por sitio.

Para leer la aceptación con la conexión administrativa PS7 definida arriba:

~~~powershell
$list = 'ef8d5b7c-9550-4fb5-b704-034924b903be'
$item = Get-PnPListItem -Connection $conn -List $list -Id 507
[pscustomobject]@{
    Acceptance=$item.Id; RunId=$item['BatchId']; Registration=$item['ReportingDeviceId']
    Manifest=$item['ManifestSha256']; HasReport=[bool]$item['PortalReportJson']
}
~~~

403 en Acceptance con la app del endpoint o acceso denegado para usuario ordinario son controles esperados. Si el receptor falla, verificar su propia app/certificado/grant sobre el sitio. En [W01–W06](../Work/SharePointUpload/README.md) están los comandos de inventario, prueba negativa, ACL, marcador y verificación de hashes. No volver a conceder acceso general como solución a una identidad equivocada.

## Comparar la generación con SharePoint

Para reproducir primero la prueba de dos ciclos completos de Priya desde un checkout del piloto, ejecutar en PS7 desde la raíz de la suite, con la conexión administrativa definida arriba:

~~~powershell
$pair = @{
    Connection=$conn
    AcceptanceListId='ef8d5b7c-9550-4fb5-b704-034924b903be'
    LandingListId='0e82d3f5-3357-4f05-b604-049e13fb9491'
    EarlierAcceptance=403
    LaterAcceptance=406
}
$repeat = & '.\ScannerPortal\Work\SharePointUpload\Test-WorkCurrentInventory.ps1' @pair
~~~

La prueba de referencia devuelve Verified, 4 observaciones, 2 rutas vigentes y 1 con coincidencias. Si la versión, SID o registro cambian, seleccionar ciclos del mismo ámbito. Para verificar de nuevo un lote **sellado** de W05C en PS5.1, usar su directorio original en la outbox histórica:

~~~powershell
$id = '387CC5B4A43602CC78968B9F980CE065856881E5CA91982AB07DC5A1F896FF38'
$batch = Join-Path $env:LOCALAPPDATA "LocalMIPScanner.WinPS51\Outbox\Pending\$id"
& '.\LocalMIPScanner.WinPS51\New-LocalMIPReportBatch.ps1' -VerifyBatch $batch
~~~

**Primera validación central del milestone de inventario vigente.** En el equipo administrativo de Sebastián, bajo la cuenta que conserva la cola Uploaded, usar PowerShell 7 y la conexión administrativa del apartado de catálogo. Usar un checkout actualizado de la rama del piloto que incluya la versión 0.3.0 del script. El siguiente bloque permite descargar solo ese archivo. Para una repetición con idéntico código, copiar en `$ref` el SHA del commit desde el enlace permanente de GitHub.

~~~powershell
$ErrorActionPreference = 'Stop'
$ref = 'work/scannerportal-history-pilot'
$url = "https://raw.githubusercontent.com/ProfKaz/PurviewScripts/$ref/Endpoint%20MIP%20Scanner/ScannerPortal/Work/SharePointUpload/Get-WorkGenerationInventory.ps1"
$tool = Join-Path $env:TEMP 'Get-WorkGenerationInventory.ps1'
Invoke-WebRequest -Uri $url -OutFile $tool
Unblock-File -LiteralPath $tool
$params = @{
    RunPrefix='24bc025b72ee'
    InterruptedRunId='f48aeea002294ddcb7848380ceffe293'
}
$result = & $tool @params -Connection $conn -LandingListId '0e82d3f5-3357-4f05-b604-049e13fb9491'
~~~

El modo local PS5.1 se ejecuta con `& $tool @params` sin conexión. La lectura adicional de SPO verifica manifest.json, summary.json y records.jsonl de cada lote comparado contra su hash. En el corte documentado: LandingReadback.VerifiedBatches=11, VerifiedFiles=33, Outcome=HashesVerified y CombinedDistinctObservedPaths=293. El resultado depende de los lotes aún retenidos y de los nuevos ciclos. Es una lectura independiente de Landing, no prueba la aceptación del lote interrumpido ni publica totales en Overview. Ante discrepancia de hash, conservar ambos originales e investigar la ruta, el lote y los permisos. No reprocesar como íntegro.

| Resultado | Acción |
| --- | --- |
| Partial | Buscar nuevos lotes de esa generación. |
| Closed | Localizar ClosingRunId en Run audit del mismo registro. |
| ClosedWithCoverageErrors | Revisar operaciones y rutas fallidas antes de interpretar ausencias como bajas. |
| CheckpointGap | Ordenar ciclos por resumedDirectories; comparar cada inicio con el inicio anterior + directoriesCompleted. Un salto mide directorios sin respaldo en los ciclos resumidos. Buscar en logs/*/cycle.json la ventana y el perfil, contar filas file legibles, verificar presencia de resumen terminal y localizar el RunId en Pending/Uploaded. Comparar explícitamente el lote recuperado mediante InterruptedRunId. Preservar el indicador aun cuando llegue un ciclo de cierre. |

## Repetir las pruebas locales de regresión

Desde la raíz instalada de Endpoint MIP Scanner, usar una consola x64 y los datos sintéticos de los scripts. Cada proceso independiente debe terminar en 0. Las pruebas de tenant y las operaciones de escritura W03B/W05F se ejecutan aparte sobre el destino del piloto.

~~~powershell
$tests = 'StateFormat','Inventory','Incremental','Checkpoint','Restart','ContentAudit','Measurement'
foreach ($name in $tests) {
    $path = Join-Path $PWD "LocalMIPScanner.WinPS51\tests\Test-$name.ps1"
    & powershell.exe -NoProfile -File $path
    if ($LASTEXITCODE -ne 0) { throw "Falló Test-$name con código $LASTEXITCODE" }
}
~~~

Para reproducir autenticación y decisión de política seguir [M1–M5](../../LocalMIPScanner.WinPS51/README.md). Para fallo del bootstrap con DOCX etiquetado registrar separadamente Get-FileStatus y descubrimiento en un control conocido; compartir solo errores, GUID, contadores y confianza. Nunca interpretar una ejecución cuyo motor no arrancó como «sin datos sensibles».
## Inventario por generación en el portal (web part 0.14.0)

Ejecutar en PowerShell 7.4 o posterior, con PnP.PowerShell y la cuenta que conserva la carpeta Uploaded del agente. La cuenta del portal necesita lectura de Landing y escritura en ScannerPortalExecutive. Usar el script de la misma entrega que el instalador del portal.

~~~powershell
$site = 'https://mhcybersecuritydemos.sharepoint.com/sites/ScannerPortalPilot'
$conn = Connect-PnPOnline -Url $site -ClientId 'f95bae44-e6ee-4673-a5e2-8fc1fb08cd64' -Interactive -ReturnConnection
$params = @{
    Connection = $conn
    LandingListId = '0e82d3f5-3357-4f05-b604-049e13fb9491'
    RunPrefix = '24bc025b72ee'
    InterruptedRunId = 'f48aeea002294ddcb7848380ceffe293'
    PublishGeneration = $true
}
& './ScannerPortal/Work/SharePointUpload/Get-WorkGenerationInventory.ps1' @params
~~~

La primera publicación devuelve Published después de releer el resumen. Con los mismos lotes la repetición devuelve Reused. En Consolidated inventory, usar Refresh generations y seleccionar el registro y la generación. Si aparece un conflicto de actualización, repetir el comando para incorporar el estado vigente. Si falta evidencia previamente publicada, recuperar los lotes de la misma generación antes de volver a publicar. Ante acceso denegado verificar el sitio, la identidad administrativa y los permisos de ScannerPortalExecutive.

La vista refleja la última publicación explícita. El archivo generations.json contiene contadores, identificadores y huellas de los manifiestos. El grupo de rutas recuperadas usa el mismo alcance y la ventana de interrupción. Los resultados Purview se calculan sobre las rutas con resumen. Un cierre posterior puede coexistir con una discontinuidad anterior.

### Selección de equipo y generación en 0.14.1

En Consolidated inventory, elegir Device registration y después Published generation. La segunda lista muestra las generaciones publicadas para ese registro. Refresh generations vuelve a leer el catálogo y conserva la selección mientras siga disponible. Los ciclos del listado inferior proceden de las aceptaciones recientes y pueden corresponder a otros registros.

En el piloto se verificó visualmente en 0.14.0 la generación con 293 rutas distintas, 6 recuperadas y 46 directorios en la discontinuidad. La actualización de la vista a 0.14.1 usa ese mismo catálogo.
