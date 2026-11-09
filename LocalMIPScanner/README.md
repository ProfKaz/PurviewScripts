# LocalMIPScanner

M1 genera un inventario local en modo auditoría. M2.1 añade estado incremental persistente con reanudación por directorio para distinguir archivos nuevos, modificados y sin cambios, sin leer su contenido. Lee rutas, extensiones, tamaños y fechas de modificación. Funciona en Windows con PowerShell 7.2 o posterior y con los permisos de la cuenta que lo ejecuta. Este hito solo inspecciona metadatos del sistema de archivos y escribe sus propios registros.

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

## Programador de tareas de Windows

Para un piloto, configura una tarea bajo la cuenta del usuario que puede leer las raíces, con la misma carpeta de estado y configuración en cada ejecución. La acción puede usar como programa C:\Program Files\PowerShell\7\pwsh.exe y los argumentos siguientes, ajustados a la instalación.

~~~text
-NoProfile -NonInteractive -File "C:\Deploy\LocalMIPScanner\Invoke-LocalMIPScanner.ps1" -Root "C:\Datos\Piloto" -MaxDirectories 50 -MaxSeconds 120
~~~

Para ejecutar por ventanas, usa un desencadenador periódico y la opción de omitir instancias nuevas mientras la tarea siga en ejecución (IgnoreNew). Para ejecución continua, usa un desencadenador al iniciar sesión y añade `-Continuous` `-IdleSeconds` 60. Revisa el límite total de ejecución de la tarea para el modo continuo. Los niveles de prioridad 7 y 8 están destinados al trabajo en segundo plano. Para varias raíces desde la tarea, usa un script de entrada que llame al scanner con un arreglo -Root. [Configuración de tareas en Microsoft Learn](https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/new-scheduledtasksettingsset?view=windowsserver2025-ps).

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
