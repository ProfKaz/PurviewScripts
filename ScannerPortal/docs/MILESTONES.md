# Milestones y backlog

Cada milestone se cierra por evidencia de aceptación, no por porcentaje de archivos escritos. Las estimaciones se definirán al medir volumen y acceso al tenant. Esta tabla es la fuente versionada del seguimiento; los milestones nativos de GitHub, cuando se creen, deben usar los mismos títulos.

| ID / título | Estado | Depende de | Entregables y aceptación |
| --- | --- | --- | --- |
| SP0 — Diagnóstico y arquitectura | Completado | — | Inventario local/remoto, riesgos de exportación, arquitectura, decisiones y contratos documentados. Revisión estática; sin afirmar validación del tenant. |
| SP1 — Contratos y alcance de eventos | En curso | SP0 | Esquemas versionados, muestras sintéticas, consultas User obligatorias y pruebas negativas. Validar campos reales de usuario/dispositivo/event ID y cuentas de cada scanner en laboratorio. |
| SP2 — Aprovisionamiento y configuración central | En curso (preparación del piloto) | SP1 | Instalador PowerShell idempotente desde release GitHub, bibliotecas/listas, índices, ACL, perfiles versionados y sincronizador local. Segunda instalación sin duplicados; usuario no autorizado recibe 403; equipo recupera última versión válida. |
| SP3 — Ingesta restringida y recuperable | Pendiente | SP1, SP2 | Adaptar AE y logs locales, checkpoint después de publicación, outbox y deduplicación. Cuentas ajenas jamás llegan a CSV/JSON/ADX/SharePoint. Fallo de carga y reinicio sin pérdida ni doble conteo. |
| SP4 — Portal SPFx y reportes | Pendiente | SP2, SP3 | Paquete sppkg, Inicio, Perfiles, Scanners, contenido y actividades. Consultas indexadas/paginadas, permisos efectivos y filtros reales. Medir latencia y escala; validar contraste, teclado y procedencia. |
| SP5 — Instalación desde GitHub y piloto integral | Pendiente | SP4 | Release verificable, instalación limpia, actualización/rollback, smoke test extremo a extremo y runbook. Evidencia con scanner oficial y Local MIP Scanner. |
| SP6 — Operación y endurecimiento | Pendiente | SP5 | Rotación de certificados, retención, alertas de retraso/errores, métricas y recuperación. Ejercicio de revocación, corrupción de lote y pérdida de conectividad. |

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
