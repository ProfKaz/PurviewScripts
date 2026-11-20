# ScannerPortal: arquitectura y alcance de la siguiente etapa

Estado: propuesta revisable, 20 de noviembre de 2026. Rama documental desde main; no modifica el endpoint, permisos, instalaciones ni el tenant. El PR #30 del publicador permanece independiente. Esta propuesta aclara la base M365 E3 de los documentos anteriores; las referencias a ADX y otros servicios son alternativas posteriores, no requisitos del piloto.

## Objetivo y restricciones

Administrar configuración, registrar equipos, recibir resultados y consultar descubrimiento y actividades desde SharePoint Online. Base: capacidades disponibles en Microsoft 365 E3, sin suscripción Azure, ADX, Storage Accounts ni base de datos adicional. PS5.1 continúa siendo el entorno del endpoint; el instalador administrativo puede necesitar su runtime portátil separado. Verificar licencias y permisos efectivos del tenant; la reportería propia no concede capacidades de clasificación o auditoría de otros planes.

La operación local sigue sin elevación. El portal se instala una vez por tenant/sitio y entrega un bootstrap con URL/IDs públicos. El registro del endpoint reutiliza ese destino. No reinstala el portal ni copia credenciales administrativas a los equipos.

## Situación comprobada y pendientes

- El usuario reportó pruebas satisfactorias de inventario, incremental, recuperación, SDK silencioso y etiquetado de copias Office.
- Existe un lote local sellado y verificado con 2.293 candidatos, 1.814 respuestas, 479 sin respuesta y 194 archivos con hallazgos. No equivale a recepción remota.
- Hay scripts de Foundation y contratos iniciales. No hay un portal SPFx completo ni una cadena de ingesta/proyección validada extremo a extremo.
- Activity Explorer y Advanced Hunting mostraron variaciones entre versiones del cliente. Son fuentes complementarias de correlación, no confirmación obligatoria de entrega de los eventos locales.
- El publicador de carpeta está en evaluación. El cambio CurrentUser del PR #30 no queda aprobado ni descartado por esta rama.

## Componentes y límites

| Componente | Responsabilidad |
| --- | --- |
| Portal SharePoint, después SPFx | Administración, vistas, publicación de configuración y seguimiento. Primera entrega con listas/vistas nativas. |
| Configuración | Borradores, perfiles publicados versionados, asignaciones, historial y rollback. |
| Registro | Identidad de enrolamiento, dispositivo/cuentas asociados, versión, capacidades, última comunicación y estado. |
| Entrada restringida | Recepción de lotes; separación entre archivos en tránsito, completos y rechazados. |
| Procesador central | Verificación, validación de emisor/esquema, deduplicación, recibos y proyecciones. |
| Datos consultables | Inventario actual, hallazgos actuales, ejecuciones, actividades y agregados diarios. |
| Operación | Reintentos, conciliación, alertas, cuotas, retención, recuperación y auditoría administrativa. |

SharePoint almacena y presenta, pero una biblioteca o una página SPFx no ejecuta por sí sola un procesador permanente. Para la base sin servicios adicionales se propone una tarea PowerShell en un equipo Windows administrado ya existente. La cuenta de ejecución no necesita ser administrador local; la preparación de credenciales requiere autorización administrativa del tenant. Su disponibilidad, conectividad, soporte y recuperación son responsabilidades explícitas. Si no existe ese equipo, la automatización desatendida sigue siendo un requisito pendiente: no se atribuye al navegador.

## Identidades: reutilizar la aplicación MIP

Una misma app registration puede tener permisos delegados y de aplicación. Sin embargo, son mecanismos de autorización distintos. Agregar permisos de SharePoint al registro existente no convierte la sesión del usuario en acceso independiente del usuario, ni concede esos permisos a un token destinado a otro recurso. La prueba de Graph necesita adquirir su propio token para Graph.

En delegado, la aplicación solo accede a lo que permite tanto su consentimiento como la autorización del usuario. Por ello, no resuelve el requisito de escribir en una biblioteca sin acceso para ese usuario. Ocultar la navegación tampoco cambia la autorización.

Propuesta: conservar separadas las funciones MIP, administración del portal y procesamiento central. Evaluar reutilizar la app MIP para leer configuración no secreta permitida al usuario. No agregar permisos de aplicación de escritura central a una app compartida por todos los endpoints como atajo.

Un certificado diferente por equipo bajo la misma app no crea grants por equipo: los permisos de aplicación pertenecen al principal compartido. Distribuir esa credencial o certificados asociados extendería a los endpoints los permisos de ese principal.

| Alternativa de entrega | Qué permite | Límite y estado |
| --- | --- | --- |
| Delegado usando app MIP | Reutilizar sesión y subir a un área autorizada al usuario | El usuario también tiene acceso según ACL; no cumple aislamiento fuerte. Probar consentimiento, WAM y operaciones exactas. |
| App de publicación por emisor | Acceso directo a carpeta seleccionada sin permiso SharePoint normal del usuario | La cuenta que controla la clave puede usar la API sobre esa carpeta. Coste de registros/grants y rotación; piloto independiente. |
| Recolector central | Copiar a almacenamiento final con credencial solo central | Recomendado para mantener la credencial final fuera de endpoints. Requiere definir y probar un canal de entrada: ubicación de entrega autorizada o recurso de red ya disponible. No existe recepción HTTP segura gratuita implícita en SPO. |

La recomendación para el portal es separar **entrada modificable por el emisor** de **almacenamiento aceptado controlado por el procesador**. Después de validar, el procesador copia a la biblioteca final sin permisos de emisor y emite recibo. Antes de la aceptación, el emisor puede alterar su entrada. No garantiza que un endpoint comprometido declare datos verdaderos; sí permite conservar evidencia aceptada y detectar reenvíos divergentes. La autenticación/canal de entrada es la primera prueba pendiente, no una decisión ya implementada.

## Recursos lógicos

Los nombres son propuestos; el aprovisionamiento debe reconciliarlos con los recursos Foundation existentes, sin duplicarlos.

| Recurso | Contenido / acceso |
| --- | --- |
| ScannerPortalConfig | Borradores y perfiles publicados; escritura de publicadores de configuración, lectura autenticada según asignación. Nunca secretos. |
| ScannerRegistry / ProfileAssignments | Registro y asignación explícita a dispositivo o grupo lógico. Las asociaciones de cuenta no sustituyen identidad de equipo. |
| ScannerPortalLanding | Área de entrada con permisos limitados; no es archivo histórico de confianza ni fuente directa del dashboard. |
| ScannerPortalAccepted | Lotes aceptados y manifiestos, escritura solo del procesador; evidencias con retención definida. |
| IngestionRuns / DeliveryReceipts | Estado, intentos, errores, digest, fecha y resultado de aceptación. |
| ScanRuns / DeviceHealth | Ejecuciones, cobertura, errores, versión, tiempos, CPU/RAM y retraso de reporte. |
| CurrentInventory / CurrentFindings | Estado vigente por dispositivo/archivo y hallazgo; archivo eliminado, no observado e inaccesible son estados diferentes. |
| LabelActivities / DashboardDaily | Historial de operaciones verificadas y agregados para consultas. |
| PortalAdminAudit | Quién publicó configuración, cambió asignaciones, reprocesó datos o ejecutó purgas. |

No publicar todas las rutas, identidades y errores para cualquier lector. Separar administrador, operador, analista y acceso a evidencias detalladas. Si se requieren ámbitos por área, deben aplicarse en la autorización de datos, no solo en los filtros visuales.

## Contrato mínimo con el endpoint

- schemaVersion, producerVersion, tenantId, registrationId, runId, batchId, timestamps UTC y número de secuencia con ámbito definido.
- Identidades de dispositivo/cuenta declaradas y autenticadas por separado; deviceName y UPN son atributos cambiantes. No derivar una identidad confiable solo del JSON enviado.
- perfil solicitado/aplicado, versión, hash y capacidades del cliente. Distinguir configuración deseada de configuración realmente aplicada.
- Tipo de registro: inventario, hallazgo, etiqueta observada, intento de acción, resultado, cobertura o salud.
- Estado de respuesta explícito: sin hallazgo, omitido, sin respuesta, error y no compatible no son equivalentes.
- Acción de etiqueta con antes/después, método, resultado verificado y código de error. Una etiqueta observada no prueba cuándo ni quién la aplicó.
- SIT/regla con procedencia, identificador y confianza. No presentar regex locales como catálogo completo de SIT de Purview.
- Manifiesto con archivos, tamaños, SHA-256, recuentos y rango. Nunca contenido sensible detectado, fragmentos, tokens ni documentos originales.

El transporte no depende del motor de análisis. El primer portal consume fixtures sintéticos y copias de lotes exportados; el endpoint se integra después mediante adaptador versionado.

## Recepción recuperable

Estados: PendingLocal → Uploading → UploadedUnverified → Accepted o Rejected. El endpoint conserva su lote pendiente hasta recibir un recibo coherente con su batchId y hash. La finalización de una petición de carga no basta.

El procesador comprueba autenticación y correspondencia de emisor, límites de tamaño/recuento, esquema, rutas relativas permitidas, hashes y completitud. Rechaza archivos extra o contenido inválido. Si posteriormente se admite ZIP, debe limitar expansión y bloquear traversal. Mismo emisor/batchId/hash produce el mismo resultado; mismo ID con hash distinto se pone en cuarentena. El SHA-256 identifica integridad, no autentica al emisor.

Separar recepción aceptada de proyección completa. Un recibo Accepted puede confirmar conservación del lote, mientras el panel muestra ProjectionPending. La proyección se recupera con checkpoints, IDs deterministas y transiciones condicionales/ETag; SharePoint no ofrece una transacción conjunta para todas las listas. Fallar durante la proyección debe poder reintentarse sin sumar dos veces. No ejecutar código ni aceptar rutas de almacenamiento arbitrarias procedentes del lote.

## Configuración centralizada

Administrar extensiones, inclusiones/exclusiones, límites por archivo, periodicidad, ventanas horarias, pausas, límites de trabajo por ciclo, uso de batería/red y modo inventario/auditoría/etiquetado. Configurar etiqueta por defecto y reglas de contenido solo donde el motor y formato lo soporten; proteger TXT/CSV genéricamente puede cambiar extensión y no debe activarse de forma implícita.

Flujo: borrador → validación → publicación inmutable → asignación piloto → aplicación confirmada → despliegue gradual. Precedencia determinista: base, grupo lógico, excepción explícita del dispositivo; definir conflicto entre grupos antes de habilitar asignación múltiple. Versionar reglas, esquema y contrato, con compatibilidad mínima y rollback.

Mantener última configuración válida offline. Si falla una actualización, conservar esa versión y reportar desfase. Políticas expiradas o incompatibles deben impedir cambios de documentos y permitir solo el modo seguro aprobado. Una pausa central tiene efecto cuando el agente vuelve a sincronizar, no instantáneamente estando offline. El perfil nunca contiene scripts arbitrarios, comandos ni secretos.

## Reporterías y operación central

Prioridad: cobertura y confianza antes que conteos. Mostrar inventariados, inspeccionados, omitidos por razón, sin respuesta, errores y versión de motor/perfil. Ofrecer estado actual y tendencias históricas sin contar cada reescaneo como un documento nuevo.

Reportes: hallazgos por SIT/etiqueta, dispositivo/cuenta, formato y ubicación autorizada; etiquetas observadas; LabelApplied, LabelChanged y LabelApplyFailed verificadas; salud de agentes y de ingesta; rendimiento; equipos sin comunicación; almacenamiento y retención. FileDiscovered es un evento de descubrimiento local definido, no prueba automática de un evento homónimo en Purview.

Conservar source, actor autenticado, actor declarado, applicationId, proceso cuando esté disponible, correlación y confianza de atribución. Los eventos locales identifican al scanner que los emite; una operación manual solo se conoce por fuentes externas o evidencia explícita. Un prefijo KS en un nombre no cambia la identidad auditada ni es una frontera de seguridad. No deduplicar ni atribuir actividad de Purview usando solo nombre de archivo o usuario compartido.

Incluir bloqueo de versiones defectuosas, compatibilidad PS/cliente/SDK, revocación de registro, renovación de certificados, cola pendiente/cuota local, despliegue por anillos, pausa, reintento y diagnóstico acotado. Diferenciar funciones previstas de comandos remotos implementados; no habilitar ejecución remota general desde el portal.

## Almacenamiento y capacidad

Separar estado actual, eventos históricos y agregados. Usar lotes de tamaño acotado, JSONL y compresión posterior, snapshots más deltas y tombstones solo cuando la cobertura permite confirmar eliminaciones. Conservar orden/generación y detectar secuencias faltantes antes de materializar estado.

En la fase inicial medir bytes por lote, eventos por dispositivo/día, duración, concurrencia y consultas. El modelo de capacidad incluye versiones de documentos, copias temporales, papelera y evidencia retenida. Indexar filtros y paginar en servidor; no descargar todos los eventos en el navegador ni crear una fila por escaneo repetido sin objetivo de consulta.

La estructura por dispositivo facilita trazabilidad pero no debe imponer un ámbito único por usuario/archivo indefinidamente. Los grants por carpeta rompen herencia y consumen ámbitos únicos. SharePoint documenta un umbral de vista de 5.000 elementos y un máximo soportado de 50.000 ámbitos únicos por lista/biblioteca; el primero no es una capacidad total de 5.000 documentos. Particionar y medir antes de prometer escala.

La retención/compactación completa permanece en SP7 y la escala 1.000/10.000/100.000 usuarios en SP8. Ahora solo definir contratos, métricas y campos de expiración necesarios. No implementar shrink ni borrar evidencias del piloto. Cualquier ampliación con servicios de coste adicional requerirá decisión explícita posterior.

## Secuencia propuesta, conservando SP0–SP8

| Orden de trabajo | Relación | Criterio de aceptación |
| --- | --- | --- |
| Arquitectura y permisos | Revisión SP0 / SP1 | Matriz de identidad/canal, fuente de verdad, esquema y límites aprobados. No tocar permisos de la app MIP todavía. |
| Base del portal | SP2 | Inventario/migración de Foundation, roles y bibliotecas idempotentes; lectura/escritura permitida y denegada con identidades distintas. |
| Configuración | SP2 | Crear, publicar, asignar y revertir un perfil; fixtures prueban resolución de asignación y compatibilidad. |
| Recepción y procesamiento | SP3 | Lote sintético recibido/aceptado/consultable; duplicado, corrupción, reinicio y emisor ajeno probados. Canal real autenticado validado. |
| Reportes iniciales | SP4 | Vistas nativas y proyecciones; luego SPFx. Totales conciliados con lotes, permisos y filtros paginados. |
| Integración de endpoint | SP5 | Un equipo/usuario, después varios; confirmar perfil aplicado y lote aceptado sin privilegios locales elevados. |
| Operación | SP6 | Desconexión, revocación, rotación, retrasos y recuperación. |
| Optimización y escala | SP7 / SP8 posteriores | Retención recuperable y capacidad medidas con objetivos explícitos. |

La siguiente prueba propuesta es de identidad y autorización de entrada con archivos sintéticos: comparar delegado de la app MIP contra carpeta de usuario autorizada y credencial central contra biblioteca final restringida. Debe demostrar también accesos denegados. No repetir aún un escaneo completo de C ni modificar documentos reales. La app de lectura de configuración, la autenticación de entrega y los permisos del procesador son decisiones separadas.

## Fuentes y alcance de validación

- [Permisos delegados y de aplicación](https://learn.microsoft.com/en-us/graph/permissions-overview).
- [Permisos seleccionados y grants de recursos](https://learn.microsoft.com/en-us/graph/permissions-selected-overview).
- [Límites SharePoint Online](https://learn.microsoft.com/en-us/office365/servicedescriptions/sharepoint-online-service-description/sharepoint-online-limits).
- [Umbral de vista](https://learn.microsoft.com/en-us/troubleshoot/sharepoint/lists-and-libraries/items-exceeds-list-view-threshold).

Revisión documental del repositorio y documentación Microsoft. No se realizaron cambios en Microsoft 365 ni pruebas nuevas del tenant en esta propuesta. La aceptación del diseño no equivale a prueba de capacidad, SSO o permisos efectivos.
