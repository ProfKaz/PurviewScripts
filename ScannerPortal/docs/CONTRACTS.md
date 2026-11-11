# Contratos v0.1 (propuestos)

## Perfil

Ver `config/scanner-profile.example.json`. El contenedor incluye `schemaVersion`, `profileId`, `version`, `execution`, `files` y `activityScope`. Solo `files` se materializa en la carpeta Config. `execution` se convierte en parámetros permitidos; nunca evaluar contenido como código. Rechazar versiones desconocidas, nombres de archivo extra, rutas fuera del directorio y reglas que no cumplan límites del motor. No remapear `files` a JSON de forma genérica sin validación.

La lista de cuentas es una allowlist exacta, normalizada con Trim/ToLowerInvariant, sin comodines. Cada fuente tiene su propio alcance y cursor. Para el scanner oficial se pueden restringir workloads documentados; para Local MIP Scanner usar exclusivamente los valores confirmados en el tenant. Una lista de cuentas vacía debe detener el exportador antes de conectar. Un array vacío de actividades/workloads significa sin restricción adicional, nunca sin restricción de usuario.

## Eventos normalizados

| Campo | Regla |
| --- | --- |
| schemaVersion | `1` para el futuro adaptador v1 |
| eventId | ID original con namespace de tenant/fuente; si falta, hash de campos estables canónicos, con algoritmo/versionado documentados |
| tenantId, source | Tenant y `PurviewActivityExplorer` o `LocalMIPScanner` |
| scannerKind, scannerId | `Official`, `Local` o `Unknown`; Unknown si cuenta compartida impide atribución |
| attribution | `DedicatedAccount`, `Correlated` o `Ambiguous`; ninguna inferencia oculta |
| runId, deviceId, accountId | Contexto real; null si la fuente no lo expone, nunca inventar |
| eventTimeUtc, ingestedAtUtc | ISO 8601 UTC; eventTimeUtc nullable si solo hay timestamp de ejecución |
| timePrecision, runStartedUtc | `Event`, `Run` o `Unknown`; conservar inicio real del log local |
| eventType | Inventario, hallazgo, acción de etiqueta, error o resumen; conservar activity original aparte |
| fileKey | Hash con ámbito de tenant/dispositivo/ruta normalizada; política explícita de exposición de rutas |
| ruleId, ruleOrigin, sitId | `LocalRule` o `PurviewSIT`; sitId null si no existe equivalencia validada |
| labelBeforeId, labelAfterId | Identificadores, nullable; no inferir una acción solo de una etiqueta observada |
| matchCount, outcome | Recuento y resultado; sin valores encontrados ni fragmentos de contenido |
| profileId, profileVersion, rulesHash | Configuración aplicada, cuando esté disponible |
| rawBatchId, sourceRecordId | Trazabilidad al lote restringido sin exponerlo a todos los lectores |

Los nombres exactos de campos AE se aprueban con muestras saneadas. El filtro inicial usa `User` por defecto; si la fuente usa otro campo se declara explícitamente `UserField`. No adivinar identidad usando campos no validados. La biblioteca de originales debe contener solo eventos que pasaron el filtro.

## Lote y checkpoint

Escribir un lote por fuente/alcance/rango con ID determinista, archivos JSONL, recuentos, checksum, versión del filtro y manifiesto. Publicar manifiesto de completitud solo después de verificar todos los archivos remotos. Una ejecución vacía válida también publica recibo con cero registros.

Separar cursor de exportación/publicación de cursor de proyección. El primero avanza cuando el lote está íntegro y confirmado; el segundo cuando se aplicaron todas sus claves idempotentes. Un fallo después de publicar y antes de confirmar debe permitir reconocer el mismo lote. No usar nombres basados únicamente en la hora del intento. El consumidor ignora archivos sin manifiesto completo.

Un cursor incluye tenant, fuente, hash de alcance y fin de rango UTC. Consultar con solapamiento configurable para eventos tardíos y deduplicar por eventId; reconciliar ventanas recientes. Alertar si la interrupción supera la ventana de disponibilidad de Activity Explorer (documentada hasta 30 días). No adelantar un cursor ante watermark ausente/repetido, fallo de un filtro, publicación parcial o parseo incompleto.

## Consultas AE

`New-ScannerActivityQuery` genera Filter1 User, Filter2 Activity opcional y siguiente filtro Workload opcional. Microsoft combina valores dentro de un filtro con OR y filtros distintos con AND. Mantener los mismos filtros/rango durante paginación; PageCookie caduca y un reinicio debe reconsultar el rango con deduplicación.

`Select-ScannerActivityRecord` devuelve únicamente registros con el campo de usuario declarado de tipo string y coincidencia exacta en allowlist. Campo ausente, tipo inesperado o cuenta desconocida se descartan. Si todos los registros de una página fallan por incompatibilidad de esquema, el adaptador debe emitir alerta y detener confirmación del lote; no confundir con una ventana vacía legítima.

Fuente: [Export-ActivityExplorerData](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/export-activityexplorerdata?view=exchange-ps).
