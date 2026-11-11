# Operación e instalación prevista

Este documento describe el flujo objetivo. **No existe aún `Install-ScannerPortal.ps1` ni un release instalable.** La base actual se verifica offline con `tests/Test-ActivityScope.ps1`.

## Instalación (SP2/SP5)

1. Administrador selecciona tenant y sitio(s), App Catalog, aplicaciones y grupos. Preflight comprueba versiones de PowerShell/PnP y permisos sin crearlos silenciosamente.
2. Descargar un release GitHub fijado, comprobar SHA-256 y procedencia aprobada, extraer a staging. Conservar scripts y manifest exactos para rollback. Verificar checksums protege integridad; no sustituye confianza en el release.
3. Ejecutar plan/WhatIf, revisar recursos, luego aprovisionar bibliotecas/listas, columnas e índices mediante migraciones idempotentes. Crear las ACL antes de cargar datos.
4. Publicar el paquete SPFx y configurar página y navegación. La instalación no puede concederse por sí sola consentimiento de tenant; informar requisitos administrativos concretos.
5. Publicar perfil piloto, bootstrap no secreto y certificado con permisos locales. Sincronizar y verificar hash/versión en una ejecución de auditoría.
6. Configurar copia de prueba del exportador con cursor y salida independientes. Comprobar que no exporta eventos ajenos antes de cambiar la tarea existente.
7. Ejecutar smoke test con archivo sintético, ambas fuentes y etiquetas de laboratorio. Confirmar conteos, identidad, tiempos y ausencia de datos sensibles.

## Matriz mínima de pruebas integradas

| Caso | Resultado esperado |
| --- | --- |
| Dos cuentas autorizadas y una ajena | Solo autorizadas llegan a todos los destinos; distinguir atribución |
| User ausente o estructura inesperada | Rechazo; deriva de esquema provoca alerta y lote sin confirmar |
| Fallo en página intermedia | Sin cursor nuevo; reintento del rango sin doble conteo |
| Fallo de subida y luego reinicio | Lote incompleto ignorado, reanudación y cursor solo tras confirmación |
| Crash tras publicar antes de confirmar | Reconocer ID de lote y deduplicar |
| Evento tardío | Capturado en solapamiento/reconciliación, contado una vez |
| Cambio de cuentas/workloads | Nuevo hash de alcance y backfill explícito, sin reutilizar cursor incompatible |
| Perfil corrupto/incompatible | No se activa; última versión válida y alerta |
| Equipo offline | Auditoría según política; outbox local con cuota/retención; no pérdida silenciosa |
| Certificado revocado o acceso denegado | Error visible, sin degradación a acceso anónimo |
| Lector del portal intenta editar perfil | Denegación efectiva por backend/ACL |
| Reinstalación/upgrade/rollback | Sin recursos duplicados; perfiles y evidencia preservados |

## Recuperación y observabilidad

Registrar runId, fuente, hash de alcance, ventana, páginas, registros recibidos/aceptados/rechazados, IDs de lotes, estado de carga y cursor confirmado. No registrar tokens, contenido detectado ni payload de eventos rechazados. Alertar ante atraso, esquema inesperado, reintentos agotados, espacio insuficiente y pérdida de cobertura.

No reparar cursores adelantándolos manualmente. Restaurar checkpoint anterior y reprocesar con deduplicación. Para lotes corruptos conservar evidencia restringida, marcar fallo y reexportar si está dentro de retención. Si no lo está, documentar hueco de cobertura en el portal.

Rollback del portal restaura el paquete anterior; rollback de perfil repunta a una versión inmutable compatible. Las migraciones de esquema requieren estrategia explícita de compatibilidad y backup antes de cambios destructivos. Desinstalar no elimina evidencia ni perfiles automáticamente.
