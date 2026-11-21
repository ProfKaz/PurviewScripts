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
| W03C | Leer metadatos del destino con el certificado y comprobar denegación en Config | Implementado como TestAccess; tenant pendiente |
| W04 | Crear carpeta de piloto y subir marcador sintético; descargar/verificar SHA-256 | Implementado como UploadProbe; tenant pendiente |
| W05A | Revisar configuración ACL de biblioteca y padre work-pilot | Script implementado; tenant pendiente |
| W05B–W05D | Validar usuario sin privilegios, verificar payloads y subir copia del lote real | Pendientes de la revisión |
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

### W03B recibido y siguiente W03C

El usuario confirmó Outcome=Verified, GrantedRole=write y GrantReadBackVerified=true. El grant se creó en ScannerPortalLanding para la aplicación Work, sin certificados nuevos ni archivos subidos. Esto confirma la concesión por vía administrativa, no el acceso efectivo por certificado.

Invoke-WorkSharedPublisher.ps1 versión 0.2.0 añade Step=TestAccess. Reutiliza el certificado/estado y obtiene un token client_credentials nuevo, sin importar Graph.Authentication ni iniciar login administrativo en esta ruta. Con ese token realiza solo GET de metadatos: lista Landing por IDs conocidos y raíz del drive. Valida el nombre/tipo/URL de biblioteca y la correspondencia con la raíz; no enumera contenidos ni descarga archivos.

Luego intenta leer metadatos de ScannerPortalConfig, cuyo ListId y existencia ya se verificaron en W03A por el usuario. Debe recibir 403 o 404. Un 200 es acceso inesperado y detiene la prueba; 401, fallos de red y 5xx no se contabilizan como denegación correcta. El script no acredita por sí mismo que un ID arbitrario exista: el control debe ser el recurso conocido de W03A. El resultado es una comprobación específica de lectura y denegación, no prueba de aislamiento global ni de escritura. No hay fallback a identidad administrativa.

```powershell
& $adminPS -NoProfile -File '.\Invoke-WorkSharedPublisher.ps1' `
    -Step TestAccess -TenantId 'd88f1561-bdab-46f0-b8ba-bfca21e1b5c4' `
    -SiteId 'mhcybersecuritydemos.sharepoint.com,0db65add-dc82-47f0-89a1-7a4818ee9a75,d194e373-f508-463a-8c6c-a40120c689a2' `
    -ListId '0e82d3f5-3357-4f05-b604-049e13fb9491' `
    -DriveId 'b!3Vq2DYLc8EeJoXpIGO6adXPjlNEI9TpGjGykASDGiaL104IOVzMFT7YEBJ4T-5SR' `
    -ControlListId '55f058e7-5798-42b9-9bbb-e0d8edf78a7f'
```

Compartir WORK W02B PARA COMPARTIR con Test=W03C-CertificateLibraryAccess. Outcome=Verified, LibraryReadVerified=true, DriveRootReadVerified=true y ControlReadDenied=true son los criterios. WriteAccessTested=false, OrdinaryUserAclReviewed=false y FilesUploaded=0 siguen siendo intencionales; la escritura se probará con un marcador sintético en W04.

El test actualizado usa un certificado real temporal y transportes simulados. Verifica ambas lecturas app-only, denegación 403/404 y rechazo de 200/401/500/fallo de red y de una raíz de otra biblioteca, sin conexión administrativa para esta ruta. No se hicieron llamadas al tenant por parte del agente. [Los permisos seleccionados se aplican al recurso independientemente de usar rutas sites/lists o drives/items](https://learn.microsoft.com/en-us/graph/permissions-selected-overview).

### W03C recibido y siguiente W04

El usuario confirmó lectura de lista y raíz por CertificateAppOnly, junto a 403 en Config, sin login administrativo ni cambios en SharePoint. Este es el primer acceso efectivo del publicador validado en el tenant. La escritura todavía no está probada.

Invoke-WorkSharedPublisher.ps1 0.3.0 añade Step=UploadProbe. Antes de escribir repite las comprobaciones de W03C. Crea/reutiliza work-pilot/probes/ProbeId/marker.json en Landing. El marcador se genera en memoria con datos sintéticos y los IDs públicos de tenant/app; no incluye documentos, contenido del inventario, usuario o rutas locales. No toca Outbox ni sus archivos.

El ProbeId se guarda antes de la primera escritura remota y queda vinculado al sitio/lista/drive en el estado local Work. Repetir sin ProbeId reutiliza el último para recuperarse de una caída. El contenido es determinista para ese ID. No hay un certificado por prueba/equipo ni un nuevo principal. Para una prueba nueva se puede indicar ProbeId explícito.

Las carpetas se crean con conflictBehavior=fail y solo se reutilizan si son carpetas con el nombre esperado. La carga de marker.json usa conflictBehavior=fail en la URL, nunca replace/rename. Un marcador existente se descarga y compara; si tiene tamaño/hash distinto la prueba falla sin sobrescribirlo. 409 por concurrencia provoca lectura, no reemplazo. Si el servidor escribió pero se perdió la respuesta, el siguiente intento encuentra y verifica el mismo marcador.

La descarga usa el URL preautenticado obtenido de Graph, sin enviarle el bearer token ni mostrar ese URL. Descarga el pequeño marcador a un temporal local, compara SHA-256 y elimina solo ese temporal. Conserva la carpeta y el marcador remotos para inspección; no hay operaciones DELETE ni borrado de evidencias. El token y la clave privada no se devuelven a consola.

```powershell
& $adminPS -NoProfile -File '.\Invoke-WorkSharedPublisher.ps1' `
    -Step UploadProbe -TenantId 'd88f1561-bdab-46f0-b8ba-bfca21e1b5c4' `
    -SiteId 'mhcybersecuritydemos.sharepoint.com,0db65add-dc82-47f0-89a1-7a4818ee9a75,d194e373-f508-463a-8c6c-a40120c689a2' `
    -ListId '0e82d3f5-3357-4f05-b604-049e13fb9491' `
    -DriveId 'b!3Vq2DYLc8EeJoXpIGO6adXPjlNEI9TpGjGykASDGiaL104IOVzMFT7YEBJ4T-5SR' `
    -ControlListId '55f058e7-5798-42b9-9bbb-e0d8edf78a7f'
```

Compartir WORK W04 PARA COMPARTIR. Outcome=Verified, DownloadHashVerified=true y hashes iguales son los criterios. MarkerUploadedThisRun es true solo si la escritura se confirmó en ese intento; puede ser false en una recuperación verificada. RealBatchRead=false y RealBatchUploaded=false siguen siendo obligatorios. MarkerWebUrl permite revisar el marcador desde el navegador con acceso normal autorizado. Esto no prueba ACL de usuarios ni custodia central; antes de W05 real sigue pendiente esa revisión.

La prueba local usa un certificado real temporal con HTTP simulado: primera carga y descarga, pérdida de respuesta después de escribir, repetición sin duplicados, archivo ocupando una ruta de carpeta, descarga corrupta y falta de bearer en el cliente de descarga. No se subió ningún archivo real al tenant por parte del agente. Referencias: [conflictBehavior en URL](https://learn.microsoft.com/en-us/graph/api/resources/driveitem?view=graph-rest-1.0), [descargas preautenticadas sin Authorization](https://learn.microsoft.com/en-us/graph/api/driveitem-get-content?view=graph-rest-1.0).

### W04 y repetición recibidos; siguiente W05A

El usuario confirmó la carga/descarga de un marcador de 244 bytes con SHA-256 idéntico. Confirmó después repetición con el mismo ProbeId, MarkerItemId y hash: MarkerUploadedThisRun=false y FoldersCreatedThisRun=0. El lote real permanece sin leer/subir en esta pista.

Get-WorkLibraryAcl.ps1 revisa solo la configuración de permisos antes de usar evidencia real. Se ejecuta en el PS7 portátil con PnP.PowerShell 3.2.0, usando la aplicación Setup existente y login delegado interactivo; no usa el certificado del publicador. Si falta PnP lo instala para CurrentUser. La aplicación Setup ya declara AllSites.FullControl delegado; disponer de un token capaz de escribir no implica que este script lo haga: solo llama Get-PnPWeb, Get-PnPSiteCollectionAdmin, Get-PnPList, Get-PnPFolder, Get-PnPProperty y Get-PnPGroupMember, además de conexión/desconexión. No hay cambios de ACL, aplicaciones, certificados, carpetas o archivos.

Revisa HasUniqueRoleAssignments y asignaciones de ScannerPortalLanding. Expande grupos SharePoint para clasificar miembros frente a administradores configurados de la colección de sitios. El publicador esperado se identifica por su claim de aplicación. Limited Access se reconoce por RoleType.Guest=1, sin depender del idioma del nombre. Grupos Entra anidados, otras apps, usuarios no administradores y principales desconocidos requieren revisión; errores al leer miembros no se convierten en grupos vacíos seguros. También revisa la carpeta existente work-pilot: si tiene permisos propios se clasifican, y si hereda su padre directo es la biblioteca revisada.

```powershell
& $adminPS -NoProfile -File '.\Get-WorkLibraryAcl.ps1' `
    -TenantId 'd88f1561-bdab-46f0-b8ba-bfca21e1b5c4' `
    -SiteUrl 'https://mhcybersecuritydemos.sharepoint.com/sites/ScannerPortalPilot' `
    -PortalClientId 'f95bae44-e6ee-4673-a5e2-8fc1fb08cd64' `
    -PublisherClientId '4ce79552-fbef-4b87-a9b9-abd07e5f2dca' `
    -ListId '0e82d3f5-3357-4f05-b604-049e13fb9491'
```

Compartir WORK W05A PARA COMPARTIR. ConfigurationReviewed significa que los ámbitos observados tienen administradores y el publicador esperado, grupos SharePoint solo de administradores o vacíos en ese instante, y la biblioteca no hereda permisos sin revisar. NeedsReview/Partial obliga a revisar los detalles, sin cambiar permisos automáticamente. No equivale a probar otra cuenta ni a revisar todos los subelementos: OrdinaryUserEffectiveAccessTested=false, DescendantUniquePermissionsReviewed=false y FutureTargetFolderAclReviewed=false son intencionales. La revisión del padre no acredita automáticamente permisos de carpetas preexistentes más profundas; la ruta concreta de recepción real también debe validarse.

Los administradores configurados conservan acceso. Esta prueba no resuelve grupos Entra ni garantiza membresías futuras, protección contra propietarios de la clave compartida o inmutabilidad de Landing. Una prueba con usuario distinto y la revisión del destino específico preceden al lote real.

Test-WorkLibraryAcl pasó con PnP simulado: administradores/publicador, Limited Access localizado, grupo Entra no resuelto, fallo de lectura de grupo, biblioteca heredada y excepción de permisos en el padre. No hubo consulta del tenant por el agente. Referencias: [Get-PnPList](https://pnp.github.io/powershell/cmdlets/Get-PnPList.html), [Get-PnPSiteCollectionAdmin](https://pnp.github.io/powershell/cmdlets/Get-PnPSiteCollectionAdmin.html), [Get-PnPGroupMember](https://pnp.github.io/powershell/cmdlets/Get-PnPGroupMember.html).

Corrección W05A 0.1.1: la ejecución del usuario detectó que Get-PnPProperty podía emitir RoleDefinitionBindingCollection como un solo objeto. Se separa la carga de RoleAssignments/RoleDefinitionBindings de su enumeración directa. La regresión reproduce la salida no enumerada y verifica que la colección no se trate como un RoleDefinition, incluidos múltiples roles por asignación. Pruebas locales simuladas; la repetición del tenant sigue pendiente. No cambia módulos, permisos ni certificados.

### Evidencia W05A/W05B recibida y siguiente verificación local

El usuario confirmó W05A 0.1.1: biblioteca con permisos propios, un administrador de sitio con Full Control, publicador con Contribute, sin asignaciones por revisar y work-pilot heredando. Confirmó W05B manual desde una cuenta de prueba distinta sin acceso: You need access / You don't have access to this item. Esto es evidencia manual reportada por el usuario para esa identidad y ruta, no una prueba automática de todas las cuentas ni del acceso con la clave compartida.

W05C reutiliza New-LocalMIPReportBatch.ps1 -VerifyBatch en Windows PowerShell 5.1. Verifica los tres payloads y sus hashes/tamaños, identidad del lote y coherencia de recuentos. Comparar también el hash del manifiesto con el ancla de W01. No escanea documentos, no consulta SPO y no cambia PendingUpload. El destino concreto de la futura copia todavía requiere validación; esta verificación local no autoriza otras carpetas ni prueba sus ACL.

### W05C evidence and W05D empty target (2026-11-20)
The user verified the original sealed batch 387CC5B4A43602CC78968B9F980CE065856881E5CA91982AB07DC5A1F896FF38 and original manifest 9BCDABC52B03E074B65E043B9EF6F67385BD2EFFD330327F978C102E05CF8A0B. It remains PendingUpload; no real files uploaded.

Invoke-WorkSharedPublisher.ps1 0.4.0 adds Step PrepareBatchTarget with BatchId and ExpectedManifestSha256. It creates only empty folders under work-pilot/devices/<persistent-local-guid>/batches/<lowercase-batch-id>. The device identity is independent of the shared certificate, persisted before remote creation and bound to the local computer name. Repeating the step reuses the identity and folders. A changed manifest binding fails closed. This step does not read or upload the real batch. TargetFolderAclReviewed and ReadyForRealUpload remain false: review the exact target and ancestor ACL chain before transfer. The shared credential still has library-wide write rights; folder naming does not isolate certificate holders.

Local validation: real temporary CurrentUser certificate/RSA with mocked HTTP/directory operations; target preparation/repeat stability, no file upload, changed-manifest rejection. Live W05D has not been executed by the maintainer or user yet.

### W05D live evidence / W05E exact target ACL
User-reported W05D passed: TargetPreparedEmpty, four folders created, device f7a2b480-3e1e-4249-abdf-7004226f0725, target item 012R64OL33GSAEYHR54ZDYTW623HGMM36Q; zero uploaded files/certificates. Device is a local reporting GUID, not an attested Entra device identity.
Get-WorkLibraryAcl.ps1 0.2.0 accepts optional TargetRelativePath (strict Work device/batch path) and reads each of its five ancestor/target ACL scopes in addition to the library. W05E is read-only, uses the existing Setup identity, does not enumerate documents or alter permissions. NeedsReview/Partial blocks progression. This is a point-in-time configuration review, not another user's effective access test or a protection against shared certificate holders. ReadyForRealUpload remains false pending transfer implementation and fresh batch integrity validation. Local mock-PnP tests passed; live W05E is pending.

### W05E passed; W05F real sealed batch transport (0.5.0)
User-provided W05E output: ConfigurationReviewed, NeedsReview=false, no issues; all five exact target scopes inherit the unique Landing library ACL (site administrator and expected publisher only). This is a point-in-time configuration review, not a new effective-access test.

Step UploadBatch requires the previously prepared target, original uppercase BatchId/ExpectedManifestSha256, BatchDirectory and explicit AcknowledgeTargetAclReview switch. It opens all four source files read-only with FileShare.Read for the transfer duration, checks the pinned original manifest SHA-256, sealed contract and payload names/sizes/hashes. The pinned manifest anchors the original W05C-verified identity/summary; this transport step does not recompute discovery summary counts. Rejects reparse ancestors/files, mismatched machine or saved target, and files over the pilot 64 MiB per-file limit before any payload write. It reads existing folders only and checks the saved target item ID. Upload order is records.jsonl, coverage.jsonl, summary.json, manifest.json. Each existing or newly created file is downloaded without a bearer header on the preauthenticated URL and its SHA-256/length compared. Existing files are never intentionally replaced: PUT uses conflictBehavior=fail. Interrupted/lost-response runs stop; rerun verifies and reuses existing files. No automatic retries for throttling or expired tokens in this narrow pilot.

After all four downloaded hashes match, writes an atomic local receipt under SharedPublisher/receipt-<BatchId>.json with VerifiedUtc and transport state RemoteHashVerified. The original outbox remains PendingUpload and untouched; portal ingestion is NOT confirmed. The manifest-last protocol is a transport completion convention, not a trusted portal acceptance marker or isolation against holders of the shared write credential. Receipt is local transport evidence, not a signed server acknowledgment.

Local tests execute temporary certificate/RSA operations with synthetic batch data and mocked HTTP: lost response after server write, resume, repeat without duplicates, manifest-last order, source alteration, corrupt downloaded data and missing ACL acknowledgment. No live real-batch upload has been executed by the maintainer. Live W05F remains pending user execution.

Graph semantics checked against Microsoft documentation: https://learn.microsoft.com/en-us/graph/api/resources/driveitem?view=graph-rest-1.0 (conflictBehavior URL parameter and preauthenticated downloadUrl); https://learn.microsoft.com/en-us/graph/api/driveitem-put-content (single-request upload).
