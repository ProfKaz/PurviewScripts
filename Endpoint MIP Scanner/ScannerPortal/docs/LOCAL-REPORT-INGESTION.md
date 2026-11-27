# Integración de informes locales con ScannerPortal

Diseño de evolución para un receptor HTTPS. Para la ingesta directa a Landing ya validada en el piloto E3, ver [resultados de transporte y recepción](PILOT-EVIDENCE.md) y [diagnóstico operativo](PILOT-TROUBLESHOOTING.md).

## Flujo propuesto

LocalMIPScanner en Windows PowerShell 5.1 sella un lote local y lo deja en una outbox persistente. Un receptor autenticado valida el emisor y el lote. Su identidad de servicio escribe en ScannerPortalLanding. El procesador genera las proyecciones del portal. El dispositivo conserva el lote hasta recibir confirmación de persistencia verificada.

El receptor central aloja la identidad con permisos de SharePoint (preferentemente identidad administrada si el entorno de ejecución la admite, o service principal con certificado protegido). La selección y despliegue del host forman parte de SP2. El agente se autentica ante el receptor con una identidad provisionada y revocable del dispositivo/agente. El mecanismo exacto se valida en el piloto. El usuario escaneado se conserva como sujeto del informe. Los clientes no reciben un secreto compartido que dé acceso a toda la biblioteca.

La autenticación MIP para evaluar la política del usuario conserva su flujo WAM independiente. La identidad de subida a SharePoint es la del receptor. Antes de aceptar un lote, el receptor vincula tenant/deviceId/scannerId con la identidad autorizada y valida la declaración de accountId. El estado de cumplimiento del endpoint afecta la confianza que puede darse al contenido del informe.

## Biblioteca y acceso

Usar la biblioteca ScannerPortalLanding prevista en la arquitectura, con herencia rota y permisos explícitos. Ocultarla de navegación y búsqueda cuando sea configurable. Los usuarios finales no reciben lectura, escritura ni sincronización de esta biblioteca. Administradores autorizados conservan acceso. Los analistas consultan proyecciones del portal mediante permisos propios.

Validar acceso con un usuario final, una identidad emisora y la identidad central. Probar rechazo de lectura, sobrescritura y borrado por el usuario final y por otro agente. Los permisos de escritura de Graph no se consideran un mecanismo append-only: el receptor aplica el contrato de publicación y las credenciales centrales permanecen protegidas.

Evaluar Lists.SelectedOperations.Selected con asignación explícita a la biblioteca para las operaciones concretas de carga y verificación. Como alternativa, usar Sites.Selected sobre un sitio de ingesta dedicado. Consentimiento y concesión al recurso son pasos separados. Las credenciales de aprovisionamiento del sitio son independientes de la identidad de ingesta.

## Organización y verificación

Particionar por tenant / año-mes-día / shard / dispositivo / runId. Guardar accountId estable como metadato y relación de reporte; evitar una carpeta con ACL distinta por cada usuario. Un dispositivo puede reportar distintas cuentas y una cuenta puede aparecer en varios dispositivos. El UPN es un atributo de presentación sujeto a cambios.

Cada lote incluye schemaVersion, batchId, runId, scannerId, deviceId, accountId, profileVersion, motor y versión, fechas UTC, conteos, tamaño y SHA-256. Distinguir ejecución completa, incompleta y con errores. Conservar los hallazgos aunque la acción de etiqueta sea Skipped. Excluir valores sensibles y fragmentos del documento.

Enviar bytes inmutables con batchId estable y reintentar con backoff, jitter y Retry-After. Ante el mismo batchId y hash, devolver el recibo existente. Ante distinto hash, rechazar como conflicto. Tras verificar el contenido persistido en SharePoint, confirmar un manifiesto de completitud. El recibo contiene batchId, hash, tamaño, driveId/itemId, versión/ETag y hora UTC. ETag permite control de concurrencia, no sustituye el hash de contenido. El piloto puede descargar y recalcular SHA-256 para verificar; Graph no soporta sha256Hash como propiedad de hashes.

Un reinicio entre carga, manifiesto y recibo debe recuperar el mismo lote sin doble conteo. Un archivo subido sin manifiesto completo queda pendiente y el procesador lo ignora. Conservar recibos y aplicar una política configurable de retención local después de la confirmación.

## Aceptación del piloto

- Emisor autorizado entrega un informe sintético sin permisos de biblioteca del usuario escaneado.
- Usuario final y otro emisor no pueden leer, reemplazar ni borrar informes ajenos.
- Desconexión, throttling, hash diferente y caída en cada transición preservan el lote.
- Reintento tras pérdida del recibo devuelve el mismo batchId y no duplica proyecciones.
- El portal permite relacionar resumen, hallazgos, acciones y errores con la ejecución y la versión del motor.
- Registrar métricas de pendientes, antigüedad, bytes, latencia, conflictos y entregas verificadas.

## Hitos posteriores de volumen

SP7 define retención, compresión, compactación y reconstrucción. Medir snapshots más deltas y agregados por periodo; evitar snapshots completos repetidos sin necesidad de reporte. Compactar particiones cerradas con manifiesto nuevo y validación de conteos y hashes antes de retirar originales elegibles. Mantener trazabilidad hacia los lotes origen y respetar retenciones y bloqueos legales. Recuperar ante interrupción de compactación. Contabilizar versiones, papelera, copias y cuotas de almacenamiento.

SP8 ensaya 1.000, 10.000 y 100.000 usuarios como escenarios de capacidad, no compromisos. Dimensionar también dispositivos, ejecuciones/día, eventos/ejecución, bytes, retención y concurrencia. Medir límites de API, índices, paginación y coste del receptor. Decidir almacenamiento histórico alternativo si SharePoint no satisface los objetivos medidos; conservar portal y configuración central según su alcance. Estos hitos siguen a la ingesta y reportería del piloto.

Referencias: [permisos seleccionados](https://learn.microsoft.com/en-us/graph/permissions-selected-overview), [hashes Graph](https://learn.microsoft.com/en-us/graph/api/resources/hashes?view=graph-rest-1.0).
