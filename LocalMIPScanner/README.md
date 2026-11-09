# LocalMIPScanner

M1 genera un inventario local en modo auditoría. Lee rutas, extensiones, tamaños y fechas de modificación. Funciona en Windows con PowerShell 7.2 o posterior y con los permisos de la cuenta que lo ejecuta. Este hito solo inspecciona metadatos del sistema de archivos y escribe sus propios registros.

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
| [performance.json](Config/performance.json) | Pausa de pauseMilliseconds (0 a 10 000) cada batchSize entradas enumeradas (1 a 10 000). El recorrido es secuencial y escribe registros conforme avanza. |

Cada ejecución guarda un archivo JSONL en %LOCALAPPDATA%\LocalMIPScanner\Logs. Puedes cambiar el destino con -LogDirectory. El recorrido omite automáticamente ese directorio. El archivo contiene eventos start, file, error y summary. El resumen cuenta entradas visitadas, archivos inventariados, exclusiones, puntos de reanálisis, archivos Offline y errores, e incluye el tiempo transcurrido en milisegundos. Un registro sin summary corresponde a una ejecución incompleta. Los registros incluyen rutas completas y mensajes de error. Se conservan localmente hasta que se eliminen.

## Pruebas

~~~powershell
pwsh -NoProfile -File .\tests\Test-Inventory.ps1
~~~

La prueba usa archivos sintéticos, uniones de directorio y una carpeta temporal con permiso de listado denegado. Verifica filtrado por extensión, exclusiones por carpeta, raíces solapadas, puntos de reanálisis, recuperación ante errores, integridad de un archivo, registros separados y validación de configuración. Requiere un directorio temporal en un volumen NTFS local.

Validado en Windows con PowerShell 7.6.9. Tres recorridos con la configuración de serie inventariaron 3 000 archivos TXT sintéticos por ejecución, con cero errores y tiempos de 2,74 a 4,16 segundos. La medición cubre el inventario de metadatos en este equipo.

Consulta [la revisión del script, la investigación de Microsoft y los hitos siguientes](ARCHITECTURE.md).
