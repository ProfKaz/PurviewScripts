# Milestones y backlog

Cada milestone se cierra por evidencia de aceptación, no por porcentaje de archivos escritos. Las estimaciones se definirán al medir volumen y acceso al tenant. Esta tabla es la fuente versionada del seguimiento; los milestones nativos de GitHub, cuando se creen, deben usar los mismos títulos.

| ID / título | Estado | Depende de | Entregables y aceptación |
| --- | --- | --- | --- |
| SP0 — Diagnóstico y arquitectura | Completado | — | Inventario local/remoto, riesgos de exportación, arquitectura, decisiones y contratos documentados. Revisión estática; sin afirmar validación del tenant. |
| SP1 — Contratos y alcance de eventos | En curso | SP0 | Esquemas versionados, muestras sintéticas, consultas User obligatorias y pruebas negativas. Validar campos reales de usuario/dispositivo/event ID y cuentas de cada scanner en laboratorio. |
| SP2 — Aprovisionamiento y configuración central | En curso (preparación del piloto) | SP1 | Instalador PowerShell idempotente desde release GitHub, bibliotecas/listas, índices, ACL, perfiles versionados y sincronizador local. Segunda instalación sin duplicados; usuario no autorizado recibe 403; equipo recupera última versión válida. |
| SP3 — Ingesta restringida y recuperable | En curso (ingesta asistida validada) | SP1, SP2 | Adaptar AE y logs locales, checkpoint después de publicación, outbox y deduplicación. Cuentas ajenas jamás llegan a CSV/JSON/ADX/SharePoint. Fallo de carga y reinicio sin pérdida ni doble conteo. |
| SP4 — Portal SPFx y reportes | En curso (Overview visible en SPO) | SP2, SP3 | Paquete sppkg, Inicio, Perfiles, Scanners, contenido y actividades. Consultas indexadas/paginadas, permisos efectivos y filtros reales. Medir latencia y escala; validar contraste, teclado y procedencia. |
| SP5 — Instalación desde GitHub y piloto integral | Pendiente | SP4 | Release verificable, instalación limpia, actualización/rollback, smoke test extremo a extremo y runbook. Evidencia con scanner oficial y Local MIP Scanner. |
| SP6 — Operación y endurecimiento | Pendiente | SP5 | Rotación de certificados, retención, alertas de retraso/errores, métricas y recuperación. Ejercicio de revocación, corrupción de lote y pérdida de conectividad. |

| SP7 — Retención y compactación | Posterior, pendiente | SP6 | Políticas de retención, compresión y compactación recuperable, snapshots/deltas, conteos y trazabilidad preservados. Contabilizar versiones y papelera. |
| SP8 — Capacidad de grandes organizaciones | Posterior, pendiente | SP7 | Escenarios de 1.000 / 10.000 / 100.000 usuarios, cuotas, concurrencia, latencia y decisión de almacenamiento histórico basada en medición. |

## Consola de gobierno de datos

**Recepción automática de inventario administrado (0.9, piloto).** Implementada la detección de manifiestos, validación de asignación, cola local con cursor por biblioteca y recuperación por lote. Prueba pendiente en el tenant: dejar el receptor activo, recibir un nuevo ciclo de un equipo asignado, observar la aceptación y el resumen desde una página abierta y reiniciar el receptor sin duplicar resultados. El alta de una identidad de servicio central y su operación permanente después de reiniciar el host se validarán por separado.

Secuencia del piloto: validar en SPO la actualización automática del resumen, automatizar la recepción de lotes, incorporar el registro de equipos y su última comunicación, y construir el inventario vigente. La gestión de perfiles y bajas desde el portal requiere permisos por función y auditoría. El pie del web part mostrará la versión del manifiesto SPFx a partir del próximo paquete.

| Entrega | Estado y criterio |
| --- | --- |
| Overview | Versión 0.7.0.0 instalada y visible en el sitio piloto según la validación administrativa. Lee un resumen con fecha de actualización, agrupado por identidad de reporte y cuenta. Cuenta observaciones de archivos, observaciones con hallazgos y errores de cobertura. Distingue reglas locales de SIT y admite exclusión explícita de lotes sintéticos. |
| Cobertura de la flota | Pendiente. Centralizar altas y bajas por registro, asociar dispositivos cuando la identidad sea verificable, registrar versiones de binario y perfil por separado. Un heartbeat independiente de los hallazgos debe registrar hora de recepción y estado. Comparar registros activos con el corte UTC y mostrar activos en 24 h, atrasados, nunca vistos y pendientes de primer contacto. |
| Actualización del resumen | Versión 0.8 implementada, pendiente de prueba en SPO. Al almacenar o reintentar un reporte el receptor reconcilia el resumen con las exclusiones guardadas. Una pestaña visible consulta el resumen cada minuto. La recepción desatendida de nuevos lotes y la agregación incremental siguen pendientes. |
| Inventario vigente y filtros cruzados | Pendiente. Proyectar observaciones por dispositivo, cuenta, identidad de archivo, generación y versión. Reconciliar deltas, cambios y bajas. Precalcular extensión × detector para que un filtro cruzado cuente solo coincidencias reales. Mostrar cobertura parcial y reutilización. |
| Configuración y operación | Pendiente. Editor de borrador con diferencia, validación, publicación versionada, asignación y restauración; registrar actor y fecha. Retirar registro con confirmación, revocar la credencial específica y detener la asignación; conservar evidencia histórica. Verificar qué ocurre con el caché offline y con accesos de una identidad compartida. |
| Acceso por función | Pendiente. Lectores acceden al resumen; operadores al diagnóstico y conciliación; administradores a perfiles, altas, bajas y permisos. Aplicar ACL en página, bibliotecas y listas, probar acceso directo por URL/API y restringir acceso a rutas crudas. |
| Escala | Pendiente. Actualizar proyecciones de forma incremental por aceptación y publicar particiones consistentes por período/dispositivo. Medir tiempos de ingesta, tamaño de respuesta y latencia con 1.000, 10.000 y 100.000 registros antes de definir capacidades adicionales. |

## Integración LocalMIPScanner 5.1

SP2 debe definir biblioteca de ingesta con permisos efectivos, identidad central y autenticación de agentes. SP3 incorpora outbox local, receptor, validación de emisor, carga idempotente y recibo verificado. Los hitos SP7 y SP8 son posteriores al piloto integral. Ver [contrato de integración y aceptación](LOCAL-REPORT-INGESTION.md).

## Trabajo concreto por milestone

### SP1

- [x] Contrato inicial de perfil y manifiesto de solución, sin datos del tenant.
- [x] Constructor de consultas con identidad obligatoria y filtros consecutivos.
- [x] Filtro exacto y cerrado ante usuario ausente, desconocido o ambiguo.
- [x] Pruebas sintéticas de alcance, filtros combinados y rechazo de configuración vacía.
- [ ] JSON Schema formal y validación semántica del perfil/evento.
- [ ] Capturar muestras saneadas y probar `User`, workload y actividades con identidades dedicadas en el tenant.
- [ ] Definir mapeo aprobado de campos y atribución; prueba app-only de Purview.

### SP2

- [x] Scripts iniciales de plan/registro de aplicación interactiva y creación aislada de sitio, con pruebas offline. No equivalen al instalador integral ni a validación del tenant.
- [x] Validar el registro de la aplicación, la creación de un sitio piloto y la base nativa vacía en un tenant de laboratorio. Ver [evidencia del piloto](PILOT-SETUP.md#evidencia-de-pruebas).
- [ ] Elegir sitio(s), IDs de aplicaciones y grupos de administradores/analistas.
- [ ] Manifest de recursos con tipos de columnas, índices y grants; migraciones versionadas.
- [ ] `Install-ScannerPortal.ps1`: preflight, plan/WhatIf, apply idempotente, verificación y rollback.
- [ ] Crear bibliotecas/listas sin herencia de acceso general; validar ACL con identidades de prueba antes de cargar perfiles.
- [ ] Publicador de perfil inmutable con control de concurrencia y revisión.
- [ ] `Sync-ScannerProfile.ps1` y bootstrap local: descarga, validación, materialización, caché y trazabilidad.

### SP3

- [ ] Integrar `ScannerPortal.Activity.psm1` en el exportador mediante cambio aislado y versionado, sin reemplazar la tarea activa durante desarrollo.
- [ ] Mantener User en todas las páginas y reintentos; errores de paginación invalidan el lote.
- [ ] Aplicar alcance antes de todos los destinos; registrar solo métricas de rechazos, sin payload descartado.
- [ ] Corregir orden de checkpoint y publicación, preservar estado anterior y ensayar fallos parciales.
- [ ] Checkpoint por fuente y hash de alcance; cambios de alcance inician backfill explícito.
- [ ] Solapamiento configurable para eventos tardíos, reconciliación y alerta de huecos fuera de retención.
- [ ] Adaptador de logs locales y uploader con outbox, clave idempotente, manifiesto y recibo.
- [ ] Materializar proyecciones y distinguir inventario de archivos, hallazgos y acciones de etiquetado.

### SP4–SP6

- [ ] Crear solución SPFx con versiones soportadas fijadas al comenzar implementación, lockfile y pipeline de build.
- [ ] CRUD de borradores y publicación por rol; lectura de proyecciones con filtros indexados.
- [ ] Empaquetar release con sppkg, scripts, esquema, checksums SHA-256 y documentación.
- [ ] Bootstrap GitHub fija commit/release; descarga a staging, verifica y ejecuta instalación local. No usar `iex` sobre contenido de main.
- [ ] Validar instalación/upgrade/rollback y credenciales revocadas en entorno aislado.
- [ ] Prueba de carga representativa y decisión SharePoint/ADX.

## Definition of Done

Código revisable, pruebas pertinentes y evidencia enlazada; sin secretos ni datos de producción; documentación y migración actualizadas; permisos comprobados con identidades permitidas y denegadas; errores no tratados como éxito. Un milestone que dependa de Microsoft 365 no se cierra con pruebas offline.

## Secuencia de validación integral

El [plan de pruebas T00–T14](END-TO-END-TEST-PLAN.md) concreta SP1–SP6 para LocalMIPScanner 5.1, identidades, entrega y portal. SP7/SP8 permanecen posteriores al piloto.

## Avance del piloto administrado (20 de noviembre de 2026)

SP2/SP3 incorporan [enrolamiento con certificado público, perfiles versionados/asignados, runner PS5.1 y subida con verificación](MANAGED-ENDPOINTS.md). No se cierran: Graph/PnP y tarea requieren pruebas reales. El principal compartido no aísla emisores entre sí. UploadedVerified no es Accepted por un procesador central. SP4 (editor/reportes), integración de clasificación/etiquetado SDK al runner, SP7 y SP8 permanecen pendientes.
