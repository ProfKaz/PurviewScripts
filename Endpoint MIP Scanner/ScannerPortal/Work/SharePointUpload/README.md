# Work: subida básica a SharePoint

Rama work/sharepoint-upload-basics, creada desde main después del PR #32. Esta pista no reemplaza las pruebas anteriores del cliente ni continúa el enrolamiento con certificado por equipo. No cambia instaladores, motor, perfiles, tareas o permisos del tenant. El instalador completo del portal queda para después.

## Qué ocurrió en la ejecución anterior

ControlPlane Initialize necesitaba PortalClientId para abrir una conexión PnP administrativa. El instalador no encontró .endpoint-install/portal-app.json y no recibió el parámetro. Por eso se detuvo antes de preparar la nueva app. El mensaje no prueba que el Service Principal MIP sea incorrecto ni que sus permisos de subida hayan sido validados. No repetir ControlPlane para esta pista; el diagnóstico local no necesita ese Client ID ni conecta con PnP.

## Identidad: decisión antes de multiplicar componentes

| Alternativa | Escala de credenciales | Consecuencia |
| --- | --- | --- |
| Un certificado privado compartido en todos los endpoints | Una credencial en Entra, muchas copias/importaciones y rotaciones | Todos actúan como la misma app. Extraer/usar una copia compromete el permiso compartido; no hay revocación individual por certificado. No ofrece aislamiento por equipo. Requiere distribución de la clave privada por TI, nunca GET anónimo desde SPO ni PFX/contraseña en GitHub. |
| Un certificado en un recolector central | Una clave privada en un punto controlado | Opción preferida si se busca custodia central: endpoint entrega a un canal autenticado y recolector carga a SPO. El canal y el equipo central deben existir y validarse; no asumir SMB transparente entre estaciones Entra-only ni un receptor HTTP implícito en SharePoint. |
| Identidad administrada | Azure administra la credencial de un recurso compatible | No aparece automáticamente en Windows por estar Entra joined o ser Windows 365. Evaluar para un recolector en infraestructura compatible, junto a sus dependencias/costes; no es sustituto universal en estaciones M365 E3 sin Azure. |
| Sesión delegada del usuario | Sin certificado de aplicación en el endpoint | Depende de sesión y ACL del usuario; no satisface por sí sola escritura independiente en una biblioteca sin permisos de ese usuario. |

No distribuir todavía un PFX ni crear certificados nuevos. Primero comprobar los datos disponibles. La elección de certificado compartido directo es posible como piloto si se acepta su alcance, pero no se presenta como equivalente a un recolector con clave privada central.

## Secuencia mínima

| Prueba | Acción | Estado |
| --- | --- | --- |
| W01 | Inventario local: IDs públicos guardados, certificados existentes del scanner y lotes pendientes | Script implementado; sin acceso de red |
| W02A | Consultar aplicaciones y permisos existentes en Entra con acceso administrativo de lectura | Script implementado; validación del tenant pendiente |
| W02B | Obtener un token con la identidad de carga elegida; sin crear carpetas ni cargar archivos | Pendiente de revisar W02A y decidir ubicación de credencial |
| W03A | Resolver sitio/biblioteca e inspeccionar grants de aplicación, solo lectura administrativa | Script implementado; tenant pendiente |
| W03B | Conceder write seleccionado sobre la biblioteca identificada y verificar por lectura | Script implementado; tenant pendiente |
| W03C | Comprobar acceso efectivo al destino con el certificado de la app | Pendiente de W03B |
| W04 | Crear una carpeta de piloto y subir un marcador sintético; descargar/verificar hash | Pendiente |
| W05 | Verificar y subir una copia del lote real existente, manifiesto al final y reintento | Pendiente |
| W06 | Repetición, desconexión, otra estación, rendimiento y rotación/revocación | Pendiente |

La estructura candidata para W04/W05 es biblioteca/work-pilot/devices/registrationId/batches/batchId. Si no existe un registro persistido del equipo, se definirá uno antes de subir; el nombre del equipo será metadato, no una identidad autenticada por sí solo. Un principal compartido no autentica criptográficamente al equipo que declara ese identificador.

Cada prueba tendrá un comando y resultado independiente. No escanear C de nuevo ni empaquetar todo el portal para probar conectividad. No avanzar a una carga real antes de W02–W04.

## W01: ejecución

Get-WorkUploadInventory.ps1 es autónomo para Windows PowerShell 5.1: no requiere módulos Graph/PnP, scripts auxiliares ni elevación. Se puede descargar individualmente a un directorio Work separado.

```powershell
$result = & '.\Get-WorkUploadInventory.ps1' -InstallationDirectory 'C:\Deploy\Endpoint MIP Scanner'
```

Compartir el bloque magenta WORK W01 PARA COMPARTIR. Solo muestra los IDs públicos permitidos de tres archivos de estado conocidos; no vuelca el JSON original ni tokens, contraseñas o material privado. Los certificados se listan únicamente desde CurrentUser/My y solo sujetos EndpointMIPScanner existentes; no demuestra su asociación con una app ni que sean compartidos. Una lista vacía es un resultado válido y no provoca enrolamiento.

Busca las dos colas Pending conocidas sin recorrer documentos ni crear lotes. Calcula el hash del manifiesto exclusivamente: PayloadHashesVerified=false evita confundir inventario con verificación completa. No abre los documentos ni cambia DeliveryState. Con OutboxDirectory se pueden indicar explícitamente otras colas.

## Fuentes y validación

### W01 recibido y siguiente prueba W02A

El usuario confirmó W01 en PS5.1 x64 sin elevación: un lote Sealed existente, hash de manifiesto consistente con la prueba previa, ningún certificado del scanner encontrado y ningún archivo de estado local de las tres apps. Esto no demuestra ausencia de aplicaciones en Entra ni verifica todavía los payloads.

Get-WorkEntraApplications.ps1 consulta las aplicaciones del tenant y selecciona nombres scanner/localmip/purview/Kaz Demos, más KnownClientId explícitos. Solo usa GET: resuelve permisos declarados (Role o Scope) y concesiones efectivas de aplicación del Service Principal. No confundir scopes declarados con consentimiento delegado efectivo, ni un permiso Selected con un grant sobre una biblioteca.

Se ejecuta en el PS7 administrativo portátil ya descargado, no cambia el runtime PS5.1 del scanner. Usa únicamente Microsoft.Graph.Authentication; si falta, lo instala para CurrentUser. El login administrativo solicita Application.Read.All con contexto de proceso. Puede requerir consentimiento de lectura; no solicita escritura de aplicaciones ni Sites.FullControl.All. No genera certificados ni importa claves, no lee contraseñas, no accede a SPO y no prueba autenticación app-only. Solo expone IDs, nombres, permisos y metadatos públicos de certificados; nunca su blob ni tokens. El campo KnownClientIdsWithoutLocalAppRegistration se refiere a app registrations locales, no prueba inexistencia de un enterprise application externo.

```powershell
$adminPS = Join-Path 'C:\Deploy\Endpoint MIP Scanner' '.endpoint-install\powershell-7.6.0\pwsh.exe'
& $adminPS -NoProfile -File '.\Get-WorkEntraApplications.ps1' `
    -TenantId 'd88f1561-bdab-46f0-b8ba-bfca21e1b5c4' `
    -KnownClientId 'a0e89d29-a20a-45af-8971-54fd03a25dac'
```

Compartir WORK W02A PARA COMPARTIR. Complete=false o Issues no vacío significa consulta parcial; no interpretar como ausencia de permisos. Después se decide si crear/reutilizar una app dedicada y dónde residirá el certificado único. La prueba de autenticación del publicador sigue siendo W02B.

- [Identidades administradas: recursos compatibles](https://learn.microsoft.com/en-us/entra/identity/managed-identities-azure-resources/managed-identities-status).
- [Permisos delegados y de aplicación](https://learn.microsoft.com/en-us/graph/permissions-overview).
- [Carga de archivos Graph](https://learn.microsoft.com/en-us/graph/api/driveitem-put-content).
- [Lectura de appRoleAssignments y permisos requeridos](https://learn.microsoft.com/en-us/graph/api/serviceprincipal-list-approleassignments?view=graph-rest-1.0).

Las pruebas locales de W01 verifican archivos de estado ausentes/corruptos, extracción de IDs sin divulgar otros campos y manifiestos pendientes sin alterar payloads. No prueban autenticación ni permisos de SharePoint.

Test-WorkEntraApplications prueba el alcance de lectura solicitado, peticiones GET, resolución de permisos efectivos frente a declaraciones y minimización de salida con Graph simulado. No se ejecutó login ni consulta del tenant por parte del agente.

### W02A recibido y preparación W02B1

El usuario confirmó W02A completo: existen Setup y MIP Lab, ambas sin permisos de aplicación efectivos y sin certificados registrados. Los scopes declarados siguen siendo de administración/MIP delegados; no acreditan acceso app-only para subir informes. Se preservan esas dos aplicaciones.

Invoke-WorkSharedPublisher.ps1 es autónomo y separa dos operaciones:

1. Prepare (W02B1): crea/reutiliza Kaz Demos Scanner Publisher - Work y su Service Principal, declara/consiente Lists.SelectedOperations.Selected y registra un único certificado público. El certificado privado se genera una sola vez en CurrentUser/My, sin ID por equipo. Se conserva la referencia en %LOCALAPPDATA%/EndpointMIPScanner/Work/SharedPublisher/publisher.json. Repetir en esa ubicación reutiliza app, certificado y concesión. Si existe la app sin estado local se requiere ClientId explícito; si hay claves desconocidas o permisos más amplios se detiene sin sustituir claves.
2. Authenticate (W02B2): obtiene únicamente un token client_credentials con ese certificado, sin login administrativo. No devuelve el token ni hace peticiones a SPO. Se ejecutará después de revisar W02B1.

Prepare solicita Application.Read.All, Application.ReadWrite.All y AppRoleAssignment.ReadWrite.All a la sesión administrativa de proceso. Estos permisos son para quien prepara, no para la aplicación del endpoint. No solicita Sites.FullControl.All ni necesita PortalClientId/PnP. Crear/consentir permisos de aplicación exige la autorización administrativa adecuada del tenant.

Para el piloto de certificado único reutilizable, AllowCertificateExport permite exportación futura desde Windows, pero no exporta la clave ni crea un PFX. Sin el switch el certificado será no exportable y quedará para uso central en esa cuenta. Elegir la política en la primera ejecución: repetir no la cambia. No se implementa distribución a otros endpoints, descarga de claves desde SPO ni rotación masiva. Todos los consumidores futuros de esa clave actuarán como la misma app.

```powershell
& $adminPS -NoProfile -File '.\Invoke-WorkSharedPublisher.ps1' `
    -Step Prepare -AllowCertificateExport `
    -TenantId 'd88f1561-bdab-46f0-b8ba-bfca21e1b5c4'
```

Compartir WORK W02B PARA COMPARTIR con Test=W02B1-SharedPublisherPrepare. Todavía no se otorga permiso a biblioteca/carpeta: el consentimiento Selected por sí solo no autoriza acceso a contenido. Ni Prepare ni Authenticate acceden al lote existente, instalan el portal o cambian tareas. No ejecutar otro enrolamiento por estación.

La prueba local Test-WorkSharedPublisher usa un certificado CurrentUser real con opción exportable explícita y transportes Graph/token simulados. Comprueba repetición sin duplicados, solo certificado público enviado, firma RSA verificable, autenticación separada de administración, salida sin token y rechazo de permisos inesperados antes de actualizar credenciales. No sustituye Prepare/Authenticate reales del tenant.

### W02B validado por el usuario y siguiente W03A

El usuario confirmó Prepare y luego TokenAcquired con CertificateAppOnly, 3599 segundos de validez, sin devolver el token ni subir archivos. Esto valida la autenticación del publicador; no demuestra permisos sobre una biblioteca.

Get-WorkSharePointTarget.ps1 es autónomo para PS7 administrativo. Solicita Sites.Read.All delegado y solo usa GET. Resuelve el sitio por URL, lista bibliotecas incluyendo la faceta system para no omitir recursos ocultos, selecciona ScannerPortalLanding por nombre exacto y obtiene ListId/DriveId. Inspecciona las concesiones a la app únicamente en esa biblioteca. No crea biblioteca/carpeta, no usa la clave privada del publicador, no concede permisos y no abre el lote ni archivos de contenido.

```powershell
& $adminPS -NoProfile -File '.\Get-WorkSharePointTarget.ps1' `
    -TenantId 'd88f1561-bdab-46f0-b8ba-bfca21e1b5c4' `
    -SiteUrl 'https://mhcybersecuritydemos.sharepoint.com/sites/ScannerPortalPilot' `
    -PublisherClientId '4ce79552-fbef-4b87-a9b9-abd07e5f2dca'
```

Compartir WORK W03A PARA COMPARTIR. Outcome=Inspected y LibraryFound=true identifican el destino, no prueban escritura del publicador. PublisherGrantsAtLibrary vacío es válido: todavía no se otorgó acceso al recurso en esta pista. Una consulta de permisos fallida genera Partial e Issues, nunca se presenta como inspección completa sin grants. OrdinaryUserAclReviewed=false recuerda que Hidden no demuestra aislamiento de usuarios; los grants de aplicación no equivalen a revisar ACL efectivas de usuarios ni herencia. Una biblioteca ausente devuelve LibraryNotFound y las alternativas existentes sin crear nada.

Test-WorkSharePointTarget prueba con Graph simulado el alcance de lectura, consultas GET, inclusión de recursos ocultos, resolución de ListId/DriveId, grants presentes/ausentes, denegación parcial y biblioteca ausente. Se ejecutó análisis sintáctico y catálogo de scripts; no se consultó SharePoint real por parte del agente.

Fuentes: [enumeración y faceta system](https://learn.microsoft.com/en-us/graph/api/list-list?view=graph-rest-1.0), [lectura de permisos de lista](https://learn.microsoft.com/en-us/graph/api/list-list-permissions?view=graph-rest-1.0), [consentimiento Selected y grant de recurso](https://learn.microsoft.com/en-us/graph/permissions-selected-overview).

### W03A recibido y siguiente W03B

El usuario confirmó biblioteca ScannerPortalLanding encontrada, IDs del sitio/lista/drive resueltos, Hidden=true, sin concesiones para la app publicadora y sin errores. La revisión de ACL de usuarios ordinarios sigue pendiente; no inferir protección a partir de Hidden.

Set-WorkSharePointLibraryGrant.ps1 es Plan por defecto. Apply añade una sola concesión write a la aplicación Kaz Demos Scanner Publisher - Work sobre ScannerPortalLanding, validando primero tenant, aplicación, URL del sitio, ID y nombre/tipo de biblioteca. Solo puede escribir mediante POST al endpoint de permisos de esa lista. No concede permisos al sitio ni a Config, no cambia roles desconocidos ni elimina concesiones. Repetir reutiliza el mismo grant. Después del POST consulta el recurso para verificar; si hay demora solo repite lecturas.

La sesión administrativa pide Application.Read.All y Sites.ReadWrite.All al aplicar. El publicador conserva Lists.SelectedOperations.Selected, con el grant write limitado a esa biblioteca. Estos son permisos distintos y no se amplía la app a Sites.ReadWrite.All. No requiere PnP/PortalClientId, no lee la clave privada, no genera certificados, no crea carpetas ni sube datos.

```powershell
& $adminPS -NoProfile -File '.\Set-WorkSharePointLibraryGrant.ps1' `
    -TenantId 'd88f1561-bdab-46f0-b8ba-bfca21e1b5c4' `
    -SiteUrl 'https://mhcybersecuritydemos.sharepoint.com/sites/ScannerPortalPilot' `
    -ListId '0e82d3f5-3357-4f05-b604-049e13fb9491' `
    -PublisherClientId '4ce79552-fbef-4b87-a9b9-abd07e5f2dca' -Apply
```

Compartir WORK W03B PARA COMPARTIR. Outcome=Verified y GrantReadBackVerified=true confirman la concesión administrativa. PublisherEffectiveAccessTested=false es intencional: la siguiente W03C usará el certificado. W04 escribe un marcador sintético; antes de W05 con evidencia real se debe revisar acceso efectivo de usuarios, herencia y alcance compartido. La concesión de una app es una modificación de seguridad del recurso; este script no demuestra el aislamiento de usuarios ni verifica todas las concesiones heredadas o por carpeta.

Test-WorkSharePointLibraryGrant pasó con Graph simulado: Plan sin escritura, payload de write exacto a la única biblioteca, lectura posterior, repetición sin duplicado y rechazo de otra app, otra biblioteca o rol inesperado. No se concedió acceso real por parte del agente. [API y permiso delegado mínimo para crear la concesión](https://learn.microsoft.com/en-us/graph/api/list-post-permissions?view=graph-rest-1.0).
