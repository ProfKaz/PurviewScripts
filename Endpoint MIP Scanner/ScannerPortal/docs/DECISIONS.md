# Registro de decisiones

| ADR | Decisión | Motivo / consecuencia |
| --- | --- | --- |
| 001 | SPFx + React + Fluent UI en SharePoint | Extensión del host solicitado; no crear hosting externo ni modificar el portal Microsoft. Versiones se fijan en SP4. |
| 002 | Configuración oculta con ACL y versiones | Hidden no es autorización. Separa borrador, publicación y rollback. |
| 003 | Secretos fuera de perfiles | Certificado Windows con ACL o Key Vault; bootstrap contiene referencias públicas. |
| 004 | Dos canales de datos | Activity Explorer para evidencia disponible en Purview; logs locales para descubrimiento y auditoría del nuevo motor. |
| 005 | User obligatorio + validación de salida | Limita extracción y evita filtraciones a cualquier destino. Cuenta compartida no prueba origen. |
| 006 | Landing inmutable + proyecciones | Reprocesamiento y trazabilidad sin recorrer todo el histórico desde el navegador. |
| 007 | Confirmación después de publicación | Evita pérdida cuando falla la subida; reintentos idempotentes. |
| 008 | Base inicial aislada del runtime activo | El exportador está en ejecución y el scanner evoluciona; integración se prueba antes de cambiar tareas. |

## Entradas necesarias para cerrar SP1/SP2

Sitio y tenant objetivo; cuentas dedicadas del scanner oficial y local; identidad del exportador; App Catalog y grupos de roles; tipo de autenticación no interactiva permitido; volumen/retención; si las rutas de archivo pueden mostrarse; disponibilidad/coste aceptable de Azure para Key Vault o consulta ADX. Documentar las decisiones con referencias de IDs, nunca secretos.

## Fuera del alcance inicial

Reemplazar el motor de clasificación, garantizar equivalencia de detectores locales con Purview, ejecutar comandos remotos arbitrarios desde perfiles, reutilizar almacenes internos de Endpoint DLP o prometer que cada evento local aparecerá en Activity Explorer.
