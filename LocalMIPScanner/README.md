# LocalMIPScanner

M1 inventaría metadatos del sistema de archivos. M2.1 añade estado incremental persistente con reanudación por directorio. El piloto M3 añade detección local de contenido TXT y CSV mediante activación explícita. LocalMIPScanner funciona en Windows con PowerShell 7.2 o posterior y con los permisos de la cuenta que lo ejecuta.

## Instalador / actualizador desde GitHub

Descarga [Install-LocalMIPScanner.ps1](Install-LocalMIPScanner.ps1) y colócalo en la carpeta de destino (por ejemplo, `C:\Deploy\LocalMIPScanner`). En PowerShell 7.2+:

~~~powershell
cd C:\Deploy\LocalMIPScanner
.\Install-LocalMIPScanner.ps1
~~~

Si el instalador fue descargado mediante un navegador y Windows lo bloquea, puedes desbloquear **solo el instalador** antes de ejecutarlo: `Unblock-File -LiteralPath .\Install-LocalMIPScanner.ps1`.

Por defecto obtiene la rama `main`. Para probar M2.1 antes de integrar el PR, instala desde la rama de pruebas.

~~~powershell
.\Install-LocalMIPScanner.ps1 -Destination 'C:\Deploy\LocalMIPScanner' -Ref feat/localmipscanner-m2.1 -Unblock -NoPrompt
~~~

El instalador no requiere Git ni permisos elevados. Resuelve el commit en GitHub y obtiene su árbol para inventariar **todos** los archivos de `LocalMIPScanner`, incluidos `Config`, scripts, módulos y pruebas. Compara cada archivo con el hash de objeto Git del repositorio (SHA-1 calculado sobre `blob <length>\0 + contenido`); los archivos intactos no se descargan nuevamente. Todas las descargas se guardan temporalmente y se verifican contra el hash publicado por GitHub antes de instalarse. La conexión utiliza HTTPS. El instalador guarda la revisión y los hashes en `.localmipscanner-install.json`.

Si una configuración existente difiere de la versión del repositorio, se **respalda y reemplaza** con la versión oficial; las copias quedan en `.installer-backups` con fecha e identificador único. Si el manifiesto anterior incluye archivos que ya no existen en la revisión nueva, solo se archivan automáticamente cuando su contenido coincide con el hash previamente instalado; archivos obsoletos modificados por el usuario se conservan y se advierten. Los archivos ajenos a la instalación nunca se eliminan. El estado del scanner en `%LOCALAPPDATA%` no se borra.

El instalador ofrece al final desbloquear, de una sola vez, los `.ps1` y `.psm1` de la raíz y de `tests`. La respuesta predeterminada es **No**. `-Unblock` acepta explícitamente el desbloqueo; `-NoPrompt` evita la pregunta y no desbloquea nada salvo que también se pase `-Unblock`.

**Seguridad y limitaciones:** revisa el instalador antes de ejecutarlo y evita cambiar `-Ref` a ramas no confiables. La integridad por hash protege contra descargas incompletas, pero no autentica al autor de la rama: GitHub y el repositorio siguen siendo el origen de confianza. La instalación realiza descargas verificadas antes de reemplazar archivos, pero el conjunto completo de archivos no constituye una transacción atómica. En caso de interrupción, vuelve a ejecutar el instalador. Requiere acceso de salida a `api.github.com` y `raw.githubusercontent.com`; la API pública de GitHub aplica límites de tasa. No se ha ejecutado todavía una validación end-to-end del instalador en Windows 365.

## Ejecutar

Desde la carpeta LocalMIPScanner, ejecuta en PowerShell 7. Sustituye la ruta por una carpeta local existente, de preferencia con datos de prueba.

~~~powershell
$resultado = .\Invoke-LocalMIPScanner.ps1 -Root 'C:\Datos\Piloto'
$resultado
Get-Content -LiteralPath $resultado.logFile | ConvertFrom-Json |
    Where-Object event -eq 'error'
~~~

Puedes pasar varias raíces con -Root 'C:\Datos', 'D:\Proyectos'. Se requieren rutas absolutas en unidades locales. Las rutas UNC, unidades de red y raíces con puntos de reanálisis en su ruta quedan fuera del alcance. Durante el recorrido se omiten los puntos de reanálisis, incluidas las uniones de directorios, y los archivos marcados como Offline. Esto puede excluir carpetas y archivos de OneDrive, incluso si algunos están disponibles en el equipo. Un error en una raíz o carpeta se registra y el recorrido continúa con las demás. Si no se puede escribir el registro, la ejecución falla.

### Modos de ejecución M2.1

- Una invocación sin límites completa una generación. Si encuentra una generación activa, continúa desde el primer directorio pendiente. Si ya encuentra un marcador end, consolida esa generación y devuelve su resumen.
- `-MaxDirectories` y `-MaxSeconds` limitan el trabajo por invocación. Cero desactiva el límite correspondiente. Los límites se comprueban tras cada checkpoint. Un directorio grande puede superar el tiempo indicado, y la carga, reanudación y consolidación se miden aparte.
- `-Continuous` repite invocaciones y espera `-IdleSeconds` entre ellas (60 por defecto). Cada pasada emite su propio resumen y libera el bloqueo antes de esperar. Con enabled en false se puede repetir el inventario M1 completo. Los límites por directorio y tiempo requieren estado incremental.

~~~powershell
.\Invoke-LocalMIPScanner.ps1 -Root 'C:\Datos\Piloto' -MaxDirectories 50 -MaxSeconds 120
.\Invoke-LocalMIPScanner.ps1 -Root 'C:\Datos\Piloto' -Continuous -MaxSeconds 120 -IdleSeconds 60
~~~

El resumen incluye generation, generationComplete, directoriesCompleted, resumedDirectories, generationHasErrors y recoveredIndex. Los contadores de archivos representan el trabajo de esa invocación. deletedFiles corresponde a la consolidación de toda la generación. Si se interrumpe una invocación, puede quedar un registro de auditoría sin summary y repetirse eventos del último directorio al reanudar.

`metadataUpdatesSkipped` cuenta los archivos cuyo registro del índice se reutilizó durante la invocación. Aparece en la salida de consola y en el resumen JSONL. El scanner sigue recorriendo los directorios y comparando tamaño y fecha de escritura. Si se desactiva `detectModifiedFiles`, una decisión `unchanged` puede incluir una actualización de metadatos y quedar fuera de ese conteo.

## Configuración

Usa los archivos de Config o pasa `-ConfigDirectory` con una copia para el piloto.

| Archivo | Qué controla |
| --- | --- |
| [extensions.json](Config/extensions.json) | Extensiones exactas con punto inicial. La comparación ignora mayúsculas y minúsculas. |
| [exclusions.json](Config/exclusions.json) | Carpetas absolutas y sus descendientes. Admite variables de entorno como %SystemRoot%. |
| [incremental.json](Config/incremental.json) | Estado incremental, carpeta de estado, tamaño máximo, detección de cambios y eliminaciones, y vigencia de una clasificación futura. |
| [performance.json](Config/performance.json) | Pausa de pauseMilliseconds (0 a 10 000) cada batchSize entradas enumeradas (1 a 10 000). El recorrido es secuencial. |

El estado y los logs se guardan por defecto en %LOCALAPPDATA%\LocalMIPScanner\State y %LOCALAPPDATA%\LocalMIPScanner\Logs. Ambas carpetas se excluyen del recorrido incremental. Usa una carpeta de estado en NTFS local bajo control de la cuenta que ejecuta el scanner. Los logs, el índice y el journal contienen rutas completas. Cada invocación crea un archivo de log y su retención es manual.

Las decisiones new, modified, unchanged y due se registran en los eventos file. Se compara tamaño y fecha de escritura, por lo que un cambio que preserve ambos atributos puede pasar inadvertido. Los registros siguen en PendingClassification. Los eventos deleted se refieren a entradas del índice y se emiten tras publicar una generación completa sin errores. La revisión [del diseño y la recuperación](ARCHITECTURE.md#estado-incremental-m21) describe el tratamiento de errores y exclusiones.

### Actualizar desde M2 o cambiar el alcance

En el primer arranque, M2.1 valida y migra `inventory-state.jsonl` si existe. El archivo de M2 queda disponible para una vuelta a la versión anterior. M2.1 mantiene `inventory.index.jsonl`, `inventory.active.jsonl` y un único backup rotativo `inventory.index.backup`. Si el índice principal falla la validación y el backup es válido, restaura el backup. Si ambas copias fallan, conserva los archivos para diagnóstico y termina con error.

Si cambias raíces, filtros u opciones de detección mientras hay un journal pendiente, termina primero la generación con los parámetros originales. Si quieres reiniciar el recorrido con el alcance nuevo, detén el scanner y archiva `inventory.active.jsonl` fuera de la carpeta de estado. El siguiente arranque parte del último índice confirmado. El mismo procedimiento permite volver al índice confirmado si el journal tiene corrupción en registros completos. Las pausas y límites de ejecución se pueden ajustar entre invocaciones de la misma generación.

## Piloto M3 de auditoría de contenido

Desde la carpeta de instalación, ejecuta la prueba sintética y luego usa una raíz de prueba. Si ya tienes una generación de inventario pendiente, termina esa generación o usa una copia de la configuración con una carpeta de estado dedicada al piloto.

~~~powershell
pwsh -NoProfile -File .\tests\Test-ContentAudit.ps1
.\Invoke-LocalMIPScanner.ps1 -Root 'C:\Datos\PilotoM3' -AuditContent
~~~

`-AuditContent` requiere que el estado incremental esté habilitado. Lee TXT y CSV como texto UTF-8, con o sin BOM, y aplica las expresiones de [classifiers.json](Config/classifiers.json). La regla incluida reconoce marcadores sintéticos de la forma `PILOT-123456`. El límite de lectura predeterminado es 1 MiB por archivo y puede ajustarse hasta 4 MiB. Cada regla tiene un presupuesto de tiempo y un máximo de 1.000 coincidencias registradas por archivo.

Los eventos `contentAudit` contienen la ruta, el resultado y, si hubo coincidencias, sus recuentos por identificador de regla. El contenido leído y los valores detectados se quedan fuera del índice y de los logs. La auditoría funciona localmente y deja intactos los documentos y sus etiquetas.

El resumen muestra `contentAudited`, `contentAuditReused`, `contentAuditFilesWithMatches`, `contentAuditSkipped` y `contentAuditErrors`. Los formatos sin extractor y los archivos que exceden el límite de auditoría figuran como omitidos. Un resultado satisfactorio, con o sin coincidencias, se reutiliza mientras coincidan los metadatos y las reglas y no venza `rescanIntervalDays`. Los errores de lectura, codificación o tiempo de regla se reintentan en una generación posterior. Los contadores de auditoría local se mantienen separados de `pendingClassification`, que conserva el significado del inventario para una clasificación posterior con Purview.

Mantén `-AuditContent` y las mismas reglas al reanudar un journal activo. Aplica cambios de reglas entre generaciones. El diseño y el plan de laboratorio con Purview se detallan en [Arquitectura](ARCHITECTURE.md#piloto-m3-de-auditoría-local).

## Programador de tareas de Windows

Para un piloto, configura una tarea bajo la cuenta del usuario que puede leer las raíces, con la misma carpeta de estado y configuración en cada ejecución. La acción puede usar como programa C:\Program Files\PowerShell\7\pwsh.exe y los argumentos siguientes, ajustados a la instalación.

~~~text
-NoProfile -NonInteractive -File "C:\Deploy\LocalMIPScanner\Invoke-LocalMIPScanner.ps1" -Root "C:\Datos\Piloto" -MaxDirectories 50 -MaxSeconds 120
~~~

Para ejecutar por ventanas, usa un desencadenador periódico y la opción de omitir instancias nuevas mientras la tarea siga en ejecución (IgnoreNew). Para ejecución continua, usa un desencadenador al iniciar sesión y añade `-Continuous` `-IdleSeconds` 60. Revisa el límite total de ejecución de la tarea para el modo continuo. Los niveles de prioridad 7 y 8 están destinados al trabajo en segundo plano. Para varias raíces desde la tarea, usa un script de entrada que llame al scanner con un arreglo -Root. [Configuración de tareas en Microsoft Learn](https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/new-scheduledtasksettingsset?view=windowsserver2025-ps).

## M5 · Medir consumo y ajustar la ejecución

`Measure-LocalMIPScanner.ps1` ejecuta cada pasada en un proceso nuevo y mide CPU, memoria e I/O mediante los contadores de Windows. El muestreo predeterminado es de un segundo. Cada medición conserva `metrics.json`, `samples.csv`, la salida y los errores del proceso. El conjunto de pasadas queda en `summary.json`.

| Escenario | Trabajo medido |
| --- | --- |
| `Inventory` | Descubrimiento incremental de metadatos. Es el escenario predeterminado. |
| `ContentAudit` | Descubrimiento y lectura TXT/CSV con las reglas locales. |
| `PolicyAudit` | Evaluación de un JSONL de hallazgos con la política de Purview y el inicio de sesión silencioso. |
| `SdkSelfTest` | Prueba sintética del SDK sin conexión al tenant. |

Desde la instalación, mide primero dos pasadas del inventario para comparar con las observaciones del Administrador de tareas. El resultado conserva el número de archivos nuevos, sin cambios y modificados, además de los tiempos de carga y consolidación.

~~~powershell
$measurements = .\Measure-LocalMIPScanner.ps1 -Scenario Inventory -Root 'C:\' -RunCount 2 -IdleSeconds 30
$measurements | Select-Object scenario, run, elapsedMilliseconds, cpuMeanPercentOfMachine,
    cpuPeakSamplePercentOfMachine, peakWorkingSetMiB, sampledPeakPrivateCommitMiB, readBytes, writeBytes, metricsFile
~~~

La medición usa la carpeta de logs habitual y guarda los informes dentro de ella para excluirlos del inventario. Si usas una carpeta de logs distinta, pasa la misma con `-LogDirectory`. El alcance y el estado conservan las reglas de reanudación de M2.1. Revisa `generationComplete` y `resumedDirectories` en `workload` para distinguir una generación completa de un tramo. Para comparar una primera pasada con una repetida desde cero, usa una copia de la configuración con una carpeta de estado dedicada.

Para medir auditoría local, selecciona explícitamente una carpeta de piloto con archivos sintéticos. Después puedes medir el SDK con el JSONL de hallazgos de una pasada que tenga coincidencias mapeadas. Usa rutas completas al responder las preguntas.

~~~powershell
$pilotRoot = Read-Host 'Ruta de la carpeta de documentos del piloto'
$scanConfig = Read-Host 'Ruta de la configuración aislada del scanner para ese piloto'
$content = .\Measure-LocalMIPScanner.ps1 -Scenario ContentAudit -Root $pilotRoot -ConfigDirectory $scanConfig
$auditLog = $content.workload[0].logFile
$policyConfig = Read-Host 'Ruta completa de policy-audit.json'
$policy = .\Measure-LocalMIPScanner.ps1 -Scenario PolicyAudit -PolicyConfig $policyConfig -AuditLog $auditLog -RunCount 2
$policy | Select-Object scenario, run, cpuMeanPercentOfMachine, cpuPeakSamplePercentOfMachine,
    peakWorkingSetMiB, sdkPolicyLoaded, metricsFile
~~~

El instalador del laboratorio devuelve `DotNetPath` y `LabAssembly`. Puedes pasarlos explícitamente a la medición con esos mismos nombres de parámetro. `sdkPolicyLoaded` confirma que se cargó una política. Si no hay candidatos mapeados, el laboratorio devuelve un resumen vacío y ese indicador permanece en `false`.

La CPU media usa el tiempo de CPU del proceso dividido por la duración y por los procesadores lógicos disponibles. La CPU pico corresponde al mayor intervalo observado. La memoria incluye el pico de conjunto de trabajo reportado por Windows y los máximos muestreados de conjunto de trabajo y memoria privada comprometida. Los I/O son contadores de bytes transferidos por el proceso e incluyen operaciones atendidas desde caché. El informe mide el proceso trabajador. El consumo de servicios compartidos de Windows, como WAM, se observa por separado en el equipo. [Tiempos de proceso](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getprocesstimes), [memoria de proceso](https://learn.microsoft.com/en-us/windows/win32/api/psapi/ns-psapi-process_memory_counters_ex), [contadores de I/O](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-io_counters)

Para comparar ajustes, conserva la misma raíz, el mismo estado de caché y las mismas reglas. Cambia un ajuste por ensayo y registra también la duración y los errores. `-Priority BelowNormal` reduce la prioridad del trabajador durante la medición. Las pausas de enumeración siguen en `performance.json`. El laboratorio admite `filePauseMilliseconds` en `policy-audit.json` para espaciar los candidatos de una evaluación. El valor predeterminado es cero. Los límites de tiempo del recorrido se comprueban al terminar cada directorio y dejan fuera la carga y la consolidación.

La aceptación de M5 requiere medir una muestra representativa en Windows 365 con las aplicaciones habituales del usuario abiertas y acordar límites de CPU, memoria e I/O con esos resultados. La prueba local `tests/Test-Measurement.ps1` comprueba la captura de métricas, las pasadas independientes, la reutilización y la conservación de errores del trabajador.

## Pruebas de M2.1

Desde el directorio LocalMIPScanner, ejecuta cada prueba en un proceso PowerShell independiente sobre archivos sintéticos.

~~~powershell
pwsh -NoProfile -File .\tests\Test-Inventory.ps1
pwsh -NoProfile -File .\tests\Test-Incremental.ps1
pwsh -NoProfile -File .\tests\Test-StateFormat.ps1
pwsh -NoProfile -File .\tests\Test-Checkpoint.ps1
pwsh -NoProfile -File .\tests\Test-Restart.ps1
pwsh -NoProfile -File .\tests\Measure-Inventory.ps1 -FileCount 3000
~~~

| Prueba | Cobertura |
| --- | --- |
| Test-Inventory | M1, extensiones, exclusiones, raíces solapadas, uniones, errores de acceso e integridad de los documentos. |
| Test-Incremental | Nuevos, modificados, sin cambios y eliminados, recarga de estado y eventos de auditoría. |
| Test-StateFormat | Formato de fechas ISO, tamaños Int64 y rechazo de tamaños inválidos. |
| Test-Checkpoint | Migración, alcance, escritor concurrente, cola truncada, checksum corrupto, fallo de publicación, replay del end, backup único y recuperación. |
| Test-Restart | Terminación forzada de un proceso Windows a mitad de un directorio, seguida de una reanudación desde el checkpoint anterior. |
| Measure-Inventory | Tres pasadas M1/M2.1 en un mismo proceso. Registra tiempo de pared, CPU, memoria pico acumulada, bytes de estado/log y tiempos de carga/consolidación. |

En Windows con NTFS y PowerShell 7.6.9 pasaron las cinco pruebas. En una medición local con 3 000 archivos, M1 tardó 4,0 s, M2.1 inicial 13,4 s y M2.1 sin cambios 11,2 s. Los tiempos de CPU fueron 5,3 s, 22,3 s y 13,3 s, respectivamente. El pico acumulado del proceso fue de 145,6 MiB. Son resultados de una muestra sintética en un único equipo.

Para la validación posterior en Windows 365, ejecuta las pruebas y luego configura la tarea con una raíz de prueba pequeña. Interrumpe la tarea en una primera pasada, reinicia el equipo y confirma que continúe la misma generación. Registra CPU, memoria, actividad de disco y latencia del equipo con aplicaciones de usuario abiertas. En una VM desechable, prueba también un corte de energía durante la publicación del índice y verifica la recuperación de la copia validada. La terminación del proceso en Test-Restart no reproduce un corte eléctrico. La tarea programada, Windows 365 y el corte de energía quedan pendientes de esa validación.
