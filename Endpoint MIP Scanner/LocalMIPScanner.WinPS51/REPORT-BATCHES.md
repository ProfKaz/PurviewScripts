# Lotes locales verificables — piloto de descubrimiento

El consolidador toma el JSONL de descubrimiento del cliente Purview, el diagnóstico final con ReintentosCSV y el inventario usado como lista de candidatos. Produce un snapshot local por archivo, preserva pendientes y errores de cobertura, y crea una carpeta Pending con identidad determinista. Esta etapa prepara datos para la futura entrega SharePoint.

## Ejecución Windows PowerShell 5.1

Después de actualizar la suite con el instalador único, ejecutar desde su raíz:

```powershell
$work = 'C:\Deploy\Endpoint MIP Scanner\TestResults\DriveC-fa5364b9c3'
$params = @{
    DiscoveryReport = Join-Path $work 'Discovery-e68dab4429.jsonl'
    RetryReport = Join-Path $work 'diagnostico-final.json'
    InventoryLog = Join-Path $work 'Logs\inventory-f6e7af74d95c47938516fa4725d649fc.jsonl'
    TenantId = 'd88f1561-bdab-46f0-b8ba-bfca21e1b5c4'
}
$batch = & '.\LocalMIPScanner.WinPS51\New-LocalMIPReportBatch.ps1' @params
$check = & '.\LocalMIPScanner.WinPS51\New-LocalMIPReportBatch.ps1' -VerifyBatch $batch.BatchDirectory
```

El resumen magenta debería mostrar 2.293 candidatos, 1.814 respuestas, 479 sin respuesta, cero errores de archivo pendientes, 194 archivos con hallazgos, 13 errores de cobertura y dos reintentos incorporados, según la evidencia del piloto. Los valores se calculan desde los archivos y se validan en el equipo de pruebas; estos totales no están fijados en el código.

## Contenido y trazabilidad

- records.jsonl: un resultado vigente por ruta, SIT/conteos/confianza, estado nativo independiente del hallazgo, versión del cliente declarada en el reporte original y procedencia.
- coverage.jsonl: errores de enumeración del inventario; no convertirlos en archivos sin coincidencias.
- summary.json: conteos consolidados y resumen de SIT.
- manifest.json: versión de esquema, batchId, contexto, referencias y hashes de fuentes, tamaño/hash de cada payload y fecha de sellado.

Outbox predeterminada: %LOCALAPPDATA%\LocalMIPScanner.WinPS51\Outbox\Pending\<batchId>. El estado PendingUpload indica que el lote aún requiere entrega. La verificación local devuelve también el SHA-256 del manifiesto. No se crea un recibo de entrega SharePoint.

La salida normalizada conserva metadatos de los hallazgos y rutas. No copia valores sensibles ni fragmentos del contenido. Mantener los archivos fuente originales para investigar su procedencia, identificada por hash y número de registro. Estos archivos no se modifican.

Los dos reintentos históricos carecen de hora y versión propias: esos campos quedan null en provenance.retry. La versión de cliente del registro corresponde a la fuente original y se conserva también en provenance.original. No inferir el propietario del documento, ID Entra de usuario o dispositivo a partir del nombre de carpeta. AccountObjectId y DeviceId son contexto opcional explícito; por defecto quedan null y deberán validarse mediante el registro de emisores al implementar la entrega.

## Consistencia

Lectura UTF-8 estricta, con soporte de BOM. El piloto admite hasta 128 MiB por fuente y mantiene el mapa en memoria; la generación por streaming y particiones grandes queda para el trabajo de capacidad.

Cada resultado debe corresponder al inventario completo. Los errores PathNotFound causados por la lectura Windows-1252 de UTF-8 pueden corregirse en hasta dos pasos, únicamente si la ruta recuperada coincide exactamente con el inventario. Se conserva la ruta reportada originalmente. No se reconcilia por nombre de archivo. Los reintentos deben corresponder a resultados pendientes y una ruta puede tener un solo reintento en este diagnóstico. Ante ambigüedad, se detiene la publicación.

El batchId incorpora versión de contrato/consolidador, hashes de las tres fuentes y contexto. Repetir con los mismos datos devuelve el lote existente tras verificarlo. Otro diagnóstico genera otro batchId. El consumidor futuro debe reconciliar snapshots por archivo y ejecución, sin sumar todos los snapshots como documentos distintos.

La publicación escribe payloads y manifiesto en staging, vacía los buffers a disco, verifica conteos/hashes y renombra la carpeta completa dentro de la misma outbox. Un solo escritor mantiene el bloqueo. Los staging abandonados por interrupción se conservan fuera de Pending y no son lotes listos para entrega. Un lote existente corrupto se rechaza, sin sustituirlo silenciosamente. El hash comprueba integridad; la autorización del emisor y la verificación remota se probarán al integrar SharePoint.

## Pruebas

```powershell
& (Join-Path $PSHOME 'powershell.exe') -NoProfile -File '.\LocalMIPScanner.WinPS51\tests\Test-ReportBatch.ps1'
```

La prueba usa fixtures sintéticos con rutas Unicode, errores corregibles, reintentos con y sin coincidencias y un caso sin respuesta. Verifica rechazo de duplicados, UTF-8 inválido, un escritor competidor y corrupción, entrada pública de verificación, idempotencia y omisión de contenido sensible.
