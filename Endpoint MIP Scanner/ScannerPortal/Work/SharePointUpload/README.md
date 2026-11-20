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
| W02 | Obtener un token con la identidad elegida; sin crear carpetas ni cargar archivos | Pendiente de revisar W01 y decidir ubicación de credencial |
| W03 | Resolver sitio/biblioteca existentes y comprobar permisos | Pendiente |
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

- [Identidades administradas: recursos compatibles](https://learn.microsoft.com/en-us/entra/identity/managed-identities-azure-resources/managed-identities-status).
- [Permisos delegados y de aplicación](https://learn.microsoft.com/en-us/graph/permissions-overview).
- [Carga de archivos Graph](https://learn.microsoft.com/en-us/graph/api/driveitem-put-content).

Las pruebas locales de W01 verifican archivos de estado ausentes/corruptos, extracción de IDs sin divulgar otros campos y manifiestos pendientes sin alterar payloads. No prueban autenticación ni permisos de SharePoint.
