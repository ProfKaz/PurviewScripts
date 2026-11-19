# Diagnóstico de partida

Inspección estática y de metadatos el 10 de noviembre de 2026. Repositorio base: `41a806d144d29242c25ab2a42d52a1b490a44698`. No se ejecutaron escaneos, exportaciones ni despliegues.

## Local MIP Scanner

Se revisaron `C:\Deploy\LocalMIPScanner` y la carpeta `LocalMIPScanner/` de GitHub. La copia instalada y el repositorio son fuentes separadas: no asumir paridad de versión. El manifest local `.localmipscanner-install.json` identifica la instalación; no debe convertirse en almacén de credenciales.

| Entrada | Forma actual y destino propuesto |
| --- | --- |
| `Config/extensions.json` | Array de extensiones; `files.extensions.json` del perfil central |
| `Config/exclusions.json` | Array de rutas con variables Windows; `files.exclusions.json` |
| `Config/performance.json` | `batchSize`, `pauseMilliseconds`; `files.performance.json` |
| `Config/incremental.json` | Activación, reescaneo, cambios/borrados, tamaño máximo, estado; `files.incremental.json` |
| `Config/classifiers.json` | `maxBytes` y reglas `id/pattern`; `files.classifiers.json` |
| `-Root` | Raíces de ejecución; `execution.roots`, fuera de los cinco archivos actuales |
| `-AuditContent` | Selecciona auditoría local; `execution.auditContent` |
| `-LogDirectory`, `-MaxDirectories`, `-MaxSeconds`, `-Continuous`, `-IdleSeconds` | Opciones del proceso, separadas del formato de configuración del scanner |
| `labs/MipSdkAudit/policy-audit.example.json` | `tenantId`, `clientId`, raíces, reglas con `ruleId/sitId/confidence`, `maxFiles`; contrato independiente del laboratorio |

`Invoke-LocalMIPScanner.ps1` acepta `-ConfigDirectory`: permite introducir sincronización central sin reescribir el motor. El instalador ya resuelve un commit de GitHub, valida blobs, prepara descargas y respalda configuración modificada. La configuración central debe aplicarse después de instalar el código y antes de arrancar el proceso, con rollback separado.

El estado incremental y los logs permanecen locales; no son configuración compartida. `%LOCALAPPDATA%` depende de la identidad real de la tarea. La auditoría local emite `contentAudit`, `outcome`, `rulesHash`, `matchesByRule` y, en algunos resultados, `sha256`. El inicio contiene `runId/startedUtc`; no todos los eventos individuales tienen timestamp. El adaptador debe propagar el contexto y distinguir hora de ejecución de hora exacta del evento.

## Activity Explorer

Fuente inspeccionada: `C:\MyDev\Activity Explorer\OFG - Activity Explorer\scripts\Invoke-AEExport.ps1` y módulos `src/AE.ActivityExplorer.psm1`, `src/AE.SharePoint.psm1`. La tarea `\ActivityExplorer\ActivityExplorerADXExport` apunta a ese script, con `-ConfigPath ...\config\ActivityExplorer.config.json -RunAsTask`. El estado observado era Running. No se inspeccionaron ni copiaron credenciales del archivo de configuración.

- El módulo actual combina actividad y workload mediante `Filter1/Filter2`. No expone cuenta de servicio ni `Filter3`.
- El destino puede ser ADX, archivos o SharePoint. La subida de archivos usa Microsoft Graph; existe soporte de sesiones de carga para archivos grandes.
- `Write-AETimeStampState` se ejecuta antes de `Send-AEFileToSharePoint`. Un fallo de publicación puede adelantar el cursor y omitir esa ventana en la próxima ejecución.
- Un watermark vacío o repetido genera warning y abandona el filtro; debe tratarse como ejecución incompleta, sin confirmar checkpoint.
- El filtro de cuentas debe aplicarse en el servidor y validarse otra vez **antes** de CSV, JSON y ADX. Un filtro solo en el dashboard no cumple el requisito.
- No copiar el exportador completo al repositorio público: integrar posteriormente un adaptador o una distribución saneada y versionada.

## Límites y validaciones pendientes

Activity Explorer documenta filtros `User`, `Activity`, `Workload` y workloads `OnPremisesFileShareScanner` y `OnPremisesSharePointScanner`. El workload observado de Local MIP Scanner debe validarse con eventos del tenant. No asignarlo automáticamente al workload del scanner oficial.

Filtrar por cuenta atribuye a una identidad, no demuestra el proceso que originó la actividad. Recomendación: cuentas dedicadas por scanner o correlación con dispositivo, aplicación y ejecución cuando esas señales existan. Una identidad compartida entre soluciones produce procedencia ambigua y debe mostrarse como tal.

No se conocen todavía el sitio destino, App Catalog, cuentas autorizadas, volumen diario, retención requerida, licencias ni consentimiento de aplicaciones. Son entradas de SP1/SP2; no impiden preparar contratos y arquitectura.

Fuentes: [Export-ActivityExplorerData](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/export-activityexplorerdata?view=exchange-ps), [SPFx](https://learn.microsoft.com/en-us/sharepoint/dev/spfx/sharepoint-framework-overview).
