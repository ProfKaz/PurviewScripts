# Plan de validación integral — LocalMIPScanner y ScannerPortal

Estado: plan propuesto. Las pruebas siguientes están pendientes hasta disponer de evidencia del piloto. Este documento fija el objetivo y el orden de validación; los cambios de contrato se versionan.

## Objetivo final y arquitectura de referencia

El piloto se limita a Microsoft 365 E3, SharePoint Online y equipos Windows existentes. Una suscripción Azure y servicios de pago adicionales quedan fuera de los requisitos del piloto. Validar por separado las capacidades de clasificación disponibles con el licenciamiento y la política del tenant. Las capacidades observadas en un tenant de laboratorio no certifican que todas estén incluidas en E3.

Flujo base: scanner PS5.1 → outbox local → publicador PS5.1 mediante tarea de Windows → Graph → biblioteca SharePoint restringida → proyecciones y portal. El publicador usa autenticación de aplicación con certificado; el usuario escaneado queda como sujeto del informe. Procesamiento y verificación se ejecutan en un equipo Windows existente del piloto, con disponibilidad registrada. Los recibos y checkpoints se guardan como archivos. Las proyecciones usan listas SharePoint indexadas.

Separar la tarea que escanea bajo la sesión del usuario (WAM para MIP cuando corresponda) de la tarea publicadora bajo una identidad local de servicio. La clave privada del publicador tiene ACL restringida a esa identidad y administradores. El proceso de usuario entrega archivos en una cola local con permisos definidos y el publicador copia y sella los bytes antes de transmitirlos. No asumir que un informe de un endpoint comprometido es evidencia incorruptible.

El piloto inicial prueba un equipo y una aplicación publicadora con certificado local. Antes de ampliar a varios equipos se requieren identidades/grants separables y revocables por emisor, o un recolector Windows existente. No distribuir un único certificado compartido con acceso a toda la biblioteca. La biblioteca no concede acceso al usuario final. Un administrador local conserva capacidad de intervención sobre su dispositivo.

## Identidades y aprovisionamiento automático

| Identidad | Tratamiento y permisos |
| --- | --- |
| Aplicación MIP existente | Reutilizar tenantId/clientId y permiso MIP de la configuración validada. |
| Aplicación de instalación de ScannerPortal | Reutilizar por ClientId explícito para tareas administrativas. Sus scripts existentes todavía requieren PS7.4/PnP y no son un upsert. Esta dependencia se limita al equipo administrador. |
| Publicador del piloto | Crear/reutilizar aplicación y service principal dedicados con certificado. Probar Files.SelectedOperations.Selected con grant write en la carpeta del emisor para las operaciones de carga y lectura de verificación. Consentimiento y concesión al recurso se comprueban por separado. Si esta operación no funciona con ese alcance, documentar el resultado antes de elegir un alcance mayor. |
| Procesador / portal | Certificado independiente en un equipo Windows existente, lectura de landing y escritura de proyecciones según función. Analistas acceden a proyecciones. |

El aprovisionador crea biblioteca/carpeta, certificado, credencial pública y grants; conserva IDs y thumbprint. No exporta la clave privada. La reejecución reconoce los recursos existentes y no rota certificados sin solicitar esa operación. El receptor Azure y su API dejan de ser entregables obligatorios. El ID del emisor y la cuenta declarada se validan contra el registro autorizado antes de proyectar sus lotes.

El futuro instalador ofrece Plan y Apply. Antes de cambios, registra tenant, IDs existentes, permisos actuales, recursos y dependencias. Resuelve permisos por resource app y nombre de permiso; conserva permisos existentes y agrega solo los faltantes. Distingue requiredResourceAccess, consentimiento efectivo/appRoleAssignment y concesión al recurso SharePoint. Una app existente no se adopta solo por displayName. Ante duplicados o tenant incorrecto, emite un error con IDs para resolver.

Persistir deploymentId e IDs del sitio, biblioteca, API, cliente e identidades. Reejecutar Apply debe producir cero objetos duplicados, consentimientos redundantes o certificados nuevos. Revocar únicamente concesiones creadas por ese despliegue durante rollback. Nunca exportar claves privadas o tokens en los registros.

## Estructura estable de datos

Bibliotecas existentes ScannerPortalConfig y ScannerPortalLanding; proyecciones existentes ScannerRegistry, ScanRuns, ContentFindings, LabelActivities, IngestionRuns y DashboardDaily. Herencia rota y permisos probados antes de introducir datos reales. Ocultar navegación es complemento de ACL, no control de acceso.

Ruta de lote: tenantId / fecha UTC / shard del deviceId / deviceId / batchId. Usuarios como metadatos accountId estable y UPN informativo. Evitar ACL individual por usuario y una lista histórica ilimitada por cada cuenta.

Contrato v1: schemaVersion, deploymentId, tenantId, deviceId, scannerId, accountId, runId, batchId, eventId, perfil y hash de reglas, motor/versión, fechas UTC, alcance, integridad de cobertura, resultado local y estado de entrega. Distinguir snapshots, deltas, inventario, hallazgos, acciones y errores. Identificar la generación base y eliminar lógicamente archivos ausentes solo al completar un alcance sin errores que lo permita. Una ejecución sin coincidencias sigue reportando cobertura y resumen. Nunca almacenar valores sensibles o fragmentos de contenido.

Cada lote tiene payload JSONL, manifiesto con conteos/tamaño/SHA-256 y recibo final. El mismo batchId/hash produce el mismo resultado; distinto hash produce conflicto. El procesador ignora lotes sin manifiesto confirmado y aplica claves eventId idempotentes. Cambios de UPN y múltiples dispositivos de un usuario preservan relaciones.

## Batería secuencial

Ejecutar un caso a la vez. Conservar salida JSON resumida, versiones, IDs, timestamps UTC y evidencia de la aceptación. Si un caso falla, conservar el lote y diagnosticar antes del siguiente caso dependiente.

| Caso | Acción | Aceptación |
| --- | --- | --- |
| T00 — Congelar entorno | Registrar PS5.1 x64, cliente Purview y SDK, commit, tenant, configuración y costes/host aprobados. Definir SLO del piloto y volumen. | Manifiesto reproducible, carpeta nueva y documentos sintéticos. Dependencias de administración diferenciadas del runtime. |
| T01 — Plan de identidades | Ejecutar preflight/Plan sin cambios. Reusar IDs MIP y portal conocidos y resolver permisos faltantes. | Lista de recursos/grants actuales y propuestos; sin secretos. |
| T02 — Aplicar y repetir | Aprovisionar API/identidad central/recursos y consentimiento. Repetir Apply. | Mismos IDs, cero duplicados y permisos efectivos comprobados. |
| T03 — Aislamiento | Usuario final intenta leer/escribir/borrar landing. Emisor intenta otra cuenta/dispositivo, otro tenant y scope incorrecto. | Acceso denegado; lotes inválidos no llegan a proyecciones. Administrador/analista acceden solo a lo autorizado. |
| T04 — Informe local | Generar TXT/CSV/DOCX sintéticos, positivos y negativos. Auditoría sin etiquetar. Sellar un lote. | Hallazgos y estado Skipped separados; errores y cobertura explícitos; originales intactos y SHA-256 reproducible. |
| T05 — Entrega mínima | Subir un lote de un usuario/dispositivo y esperar el recibo final. | Leer bytes remotos y verificar SHA-256; IDs remotos, conteo, tamaño y hora en recibo. |
| T06 — Offline | Ejecutar sin conexión, reiniciar y recuperar conexión. | Cola conserva bytes e IDs; se entrega una vez sin interacción rutinaria. |
| T07 — Cortes y reintentos | Interrumpir antes/después de subir, antes del manifiesto y antes/después del recibo. Reenviar lote. | Sin pérdida, mismo recibo y cero doble conteo. |
| T08 — Corrupción y fallos | Alterar hash, reutilizar batchId con otros bytes, simular 429/503 y expirar token. | Rechazo de corrupción/conflicto; Retry-After/backoff/jitter; pendiente recuperable con límite de cola y diagnóstico de capacidad. |
| T09 — Usuario y dispositivos | Dos usuarios en un dispositivo, un usuario en dos dispositivos y cambio de UPN. | Relaciones por IDs estables y aislamiento aplicado en el receptor. |
| T10 — Incremental | Primera pasada, repetición, archivo cambiado/creado/borrado, cambio de reglas y alcance parcial con error. | Reutilización verificable, hallazgos obsoletos reconciliados, cobertura parcial sin borrar estado vigente indebidamente. |
| T11 — Etiquetas y reportes | Aplicación/cambio en copias Office y fallo controlado; comparar evento local, AE/Hunting y recibo. | Reporte local suficiente; atribución expresa; evento remoto opcional con procedencia y sin doble conteo. |
| T12 — Portal | Materializar proyecciones y consultar por usuario, dispositivo, fecha, SIT y resultado. | Conteos coinciden con manifiestos; permisos efectivos, índices y paginación; estado de ingesta visible. |
| T13 — Operación | Tarea programada bajo sesión acordada, revocación/renovación de credenciales y actualización/rollback. | Recuperación de la última configuración válida, un escritor, cola preservada y métricas de retraso/errores. |
| T14 — Capacidad piloto | Aumentar emisores sintéticos y volumen por escalones; introducir ráfagas y desconexiones. | Medir CPU/RAM, ancho de banda, latencia p50/p95, backlog, cuotas, errores y consultas frente a SLO de T00. |

En T00–T14, las referencias a receptor/API se sustituyen por publicador local y sus concesiones seleccionadas en SharePoint. T01–T03 y T05–T08 prueban primero lotes sintéticos pequeños sin ejecutar un escaneo completo. T04 puede prepararse en paralelo manualmente al aprovisionamiento, conservando el orden de aceptación de la entrega. El cierre del piloto requiere T00–T14 con evidencia y defectos resueltos; la existencia de código o pruebas offline no cierra permisos ni comportamiento del tenant.

## Entregables de implementación

1. Instaladores independientes desde GitHub con commit/hash y manifiesto de dependencias. Comandos Windows PowerShell 5.1 para agentes. Las herramientas administrativas actuales ScannerPortal requieren PS7.4/PnP; el preflight debe informar esa dependencia y el diseño no obliga a instalarla en endpoints. La identidad central puede aprovisionarse con herramientas de administración compatibles según el host elegido.
2. Registro automático idempotente de identidades, permisos y recursos, plan, apply y validación negativa.
3. Generador local y outbox, cliente de envío, publicador autenticado y verificador/recibos.
4. Procesador idempotente y reportes del portal con métricas de ingesta.
5. Runner de pruebas por caso que genere evidencia saneada y mantenga el contexto sin depender de variables de una sesión previa.

## Posteriores al piloto

SP7 implementa retención/compactación con reconstrucción, conteos/hash antes y después, versiones/papelera y conservación legal. SP8 prueba escenarios de 1.000, 10.000 y 100.000 usuarios, además de dispositivos, eventos/día, bytes y retención; decide si el histórico necesita otro almacenamiento conservando portal y configuración SharePoint.

El contrato, particionamiento y entrega idempotente se fijan antes del piloto. Cambios incompatibles incrementan schemaVersion e incluyen migración. La compresión y retención se diseñan desde v1, pero se implementan después; no se agregan servicios de compactación durante T01–T14.

## Escalabilidad con costes explícitos

SP7 conserva el trabajo posterior de retención, compresión y compactación. SP8 evalúa límites de SharePoint, carga del equipo procesador y coste operativo antes de comprometer capacidad. Azure Functions, colas administradas, almacenamiento dedicado y ADX son alternativas posteriores con suscripción y coste adicionales. No son prerrequisitos para demostrar descubrimiento y entrega verificable en el piloto E3.