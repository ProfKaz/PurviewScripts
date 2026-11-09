# LocalMIPScanner

M1 genera un inventario local en modo auditoría. M2 añade estado incremental persistente para distinguir archivos nuevos, modificados y sin cambios, sin leer su contenido. Lee rutas, extensiones, tamaños y fechas de modificación. Funciona en Windows con PowerShell 7.2 o posterior y con los permisos de la cuenta que lo ejecuta. Este hito solo inspecciona metadatos del sistema de archivos y escribe sus propios registros.

## Instalador / actualizador desde GitHub

Descarga [Install-LocalMIPScanner.ps1](Install-LocalMIPScanner.ps1) y colócalo en la carpeta de destino (por ejemplo, `C:\Deploy\LocalMIPScanner`). En PowerShell 7.2+:

~~~powershell
cd C:\Deploy\LocalMIPScanner
.\Install-LocalMIPScanner.ps1
~~~

Si el instalador fue descargado mediante un navegador y Windows lo bloquea, puedes desbloquear **solo el instalador** antes de ejecutarlo: `Unblock-File -LiteralPath .\Install-LocalMIPScanner.ps1`.

Por defecto obtiene la rama `main`. Para probar específicamente las correcciones del PR #4 antes de fusionarlas, indica `-Ref fix/localmipscanner-m2-module-reload-pr4`. Para instalar sin preguntas y desbloquear automáticamente los scripts de la raíz y `tests`:

~~~powershell
.\Install-LocalMIPScanner.ps1 -Destination 'C:\Deploy\LocalMIPScanner' -Ref main -Unblock -NoPrompt
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

## Configuración

Usa los archivos de Config o pasa -ConfigDirectory con una copia para el piloto.

| Archivo | Qué controla |
| --- | --- |
| [extensions.json](Config/extensions.json) | Lista de extensiones exactas con punto inicial. La comparación ignora mayúsculas y minúsculas. |
| [exclusions.json](Config/exclusions.json) | Lista de carpetas absolutas y todos sus descendientes. Admite variables de entorno como %SystemRoot%. |
| [incremental.json](Config/incremental.json) | Activa el índice, el límite de tamaño, la caducidad de clasificación futura y la detección de eliminaciones. |\n| [performance.json](Config/performance.json) | Pausa de pauseMilliseconds (0 a 10 000) cada batchSize entradas enumeradas (1 a 10 000). El recorrido es secuencial y escribe registros conforme avanza. |

M2 guarda el índice en `%LOCALAPPDATA%\\LocalMIPScanner\\State\\inventory-state.jsonl` (configurable). Se excluye automáticamente la carpeta del índice. Una instancia concurrente con el mismo índice se rechaza mediante bloqueo exclusivo. La escritura usa un archivo temporal y reemplazo atómico dentro del mismo volumen. Los documentos no se modifican.

En la primera ejecución, `newFiles` registra archivos no vistos; en la segunda, `unchangedFiles` registra archivos con mismo tamaño y fecha de modificación. Las acciones `new`, `modified`, `unchanged` y `due` se añaden al campo `decision` de cada evento `file`. `deleted` se emite únicamente al completar el recorrido sin errores de enumeración. Un archivo Offline se excluye de ese cálculo. Los archivos mayores que `maxFileSizeMB` generan `skip` y `oversizedFiles`.

**Importante:** M2 no inspecciona contenido ni aplica etiquetas. `lastContentScannedUtc` permanece nulo y `pendingClassification` describe trabajo futuro. `rescanIntervalDays` solo aplica a entradas que tengan una fecha de clasificación real en hitos posteriores. No se obtiene todavía ahorro sustancial de enumeración de directorios: se recorre el árbol igualmente. La detección basada en tamaño y fecha no detecta necesariamente una modificación que preserve ambos atributos. Eliminar un archivo de un alcance más estrecho no lo elimina del índice; el estado conserva los registros fuera del alcance actual.

Cada ejecución guarda un archivo JSONL en %LOCALAPPDATA%\LocalMIPScanner\Logs. Puedes cambiar el destino con -LogDirectory. El recorrido omite automáticamente ese directorio. El archivo contiene eventos start, file, error y summary. El resumen cuenta entradas visitadas, archivos inventariados, exclusiones, puntos de reanálisis, archivos Offline y errores, e incluye el tiempo transcurrido en milisegundos. Un registro sin summary corresponde a una ejecución incompleta. Los registros incluyen rutas completas y mensajes de error. Se conservan localmente hasta que se eliminen.

## Pruebas

~~~powershell
pwsh -NoProfile -File .\tests\Test-Inventory.ps1
~~~

La prueba usa archivos sintéticos, uniones de directorio y una carpeta temporal con permiso de listado denegado. Verifica filtrado por extensión, exclusiones por carpeta, raíces solapadas, puntos de reanálisis, recuperación ante errores, integridad de un archivo, registros separados y validación de configuración. Requiere un directorio temporal en un volumen NTFS local.

Validado en Windows con PowerShell 7.6.9. Tres recorridos con la configuración de serie inventariaron 3 000 archivos TXT sintéticos por ejecución, con cero errores y tiempos de 2,74 a 4,16 segundos. La medición cubre el inventario de metadatos en este equipo.

Consulta [la revisión del script, la investigación de Microsoft y los hitos siguientes](ARCHITECTURE.md).

## Pruebas recomendadas en Windows 365 (M2)

~~~powershell
$first = .\\Invoke-LocalMIPScanner.ps1 -Root 'C:\\'
$first | Format-List
$second = .\\Invoke-LocalMIPScanner.ps1 -Root 'C:\\'
$second | Format-List
Get-Content -LiteralPath $second.logFile | ConvertFrom-Json |
    Where-Object event -eq 'error'
~~~

Es esperable que la enumeración completa continúe tardando varios minutos. Comparar `newFiles`, `unchangedFiles`, `modifiedFiles`, `stateLoadMilliseconds`, `enumerationMilliseconds` y `stateSaveMilliseconds`. No ejecutar sobre un perfil de usuario productivo con datos sensibles antes de revisar los filtros y la retención del registro de rutas.

### Actualización de M1 a M2: recarga del módulo

Si ejecutaste M1 y luego actualizaste a M2 en la misma sesión de PowerShell, el módulo anterior puede permanecer en memoria. El punto de entrada usa ahora `Import-Module -Force`. Se recomienda ejecutar los tests en procesos PowerShell independientes y nuevos:

~~~powershell
pwsh -NoProfile -File .\\tests\\Test-Inventory.ps1
pwsh -NoProfile -File .\\tests\\Test-Incremental.ps1
~~~

Comprueba que el resumen contiene `newFiles`, `unchangedFiles` y `stateLoadMilliseconds` antes de recorrer `C:\\`.

### M2: diagnóstico de archivos de prueba bloqueados

Si `Test-Incremental.ps1` informa un archivo `inventory-*.jsonl` abierto durante la limpieza, actualiza a la revisión que contiene la corrección de cierre de recursos. Antes de fusionar este PR, usa el instalador con `-Ref fix/localmipscanner-m2-cleanup-pr5`. La prueba ahora intenta limpiar su carpeta temporal varias veces, pero no sustituye el error original por un fallo de limpieza. Si se produce otra excepción, adjunta el **primer error** mostrado y su línea. Evita borrar manualmente archivos de pruebas que sigan siendo utilizados por procesos activos.

~~~powershell
.\\Install-LocalMIPScanner.ps1 -Ref fix/localmipscanner-m2-cleanup-pr5 -Unblock -NoPrompt
pwsh -NoProfile -File .\\tests\\Test-Incremental.ps1
~~~

### M2: compatibilidad del índice JSONL (PR #6)

El tamaño `sizeBytes` es un número entero JSON; al leerlo con `ConvertFrom-Json -AsHashtable`, PowerShell puede materializarlo como `Int32` o `Int64` según el valor. El cargador M2 ahora acepta ambos y los normaliza a `Int64`, sin admitir valores negativos, fraccionarios ni texto. Esto corrige el error `Invalid incremental state entry` al repetir un escaneo con archivos pequeños.

Para validar la corrección antes de su integración, actualiza explícitamente desde `-Ref fix/localmipscanner-m2-state-numeric-types-pr6` y ejecuta los dos tests en consolas independientes. No elimines manualmente el índice de producción; para el test se genera uno sintético en una carpeta temporal.
