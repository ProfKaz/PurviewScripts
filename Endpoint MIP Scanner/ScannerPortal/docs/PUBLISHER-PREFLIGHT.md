# Publicador SharePoint — preparación por dispositivo

Objetivo del piloto: usar el sitio existente https://mhcybersecuritydemos.sharepoint.com/sites/ScannerPortalPilot y ScannerPortalLanding, con una identidad de aplicación dedicada por emisor. Esta etapa prepara y prueba permisos. El lote real permanece PendingUpload.

## Ejecución

Abre Windows PowerShell 5.1 x64 **sin elevación local**, usando la misma cuenta Windows de la futura tarea, desde la instalación existente. Usa además una cuenta Entra autorizada para crear aplicaciones, consentir permisos de aplicación y administrar el sitio. La preparación administrativa se ejecuta en el PS7 gestionado por el instalador; el publicador y las comprobaciones de ejecución son compatibles con PS5.1.

```powershell
Set-Location 'C:\Deploy\Endpoint MIP Scanner'
.\Install-EndpointMIPScanner.ps1 -Ref fix/publisher-user-scope -Stage Download
.\Install-EndpointMIPScanner.ps1 -Ref fix/publisher-user-scope -Stage Publisher -TenantId 'd88f1561-bdab-46f0-b8ba-bfca21e1b5c4' -SiteUrl 'https://mhcybersecuritydemos.sharepoint.com/sites/ScannerPortalPilot'
```

El primer comando actualiza el instalador para reconocer Publisher. El segundo prepara dependencias, autentica al administrador y reutiliza el portal existente. No vuelve a crear el sitio. La biblioteca debe haber sido creada por Foundation y tener herencia rota. Ante acceso general, se detiene sin quitar permisos ajenos.

Si falta el ID administrativo del portal, se muestran candidatos por nombre y se pide un ID explícito. Esta app es diferente de la app MIP y de la nueva publicadora. El contexto queda guardado para futuras ejecuciones. La instalación solo agrega el permiso Files.SelectedOperations.Selected al publicador; su consentimiento y el grant write de la carpeta se verifican como operaciones separadas. No se amplía automáticamente a Sites.Selected ni a permisos de todo el tenant.

## Estructura

```text
ScannerPortalLanding/
  devices/
    <primeros 2 caracteres del deviceId>/
      <deviceId de registro>/
        _preflight/
        batches/
          <año UTC>/
            <mes UTC>/
              <batchId>/
                records.jsonl
                coverage.jsonl
                summary.json
                manifest.json
```

La preparación crea devices/prefijo/deviceId y la carpeta de comprobación. batches/año/mes/lote se materializa al implementar la entrega. El deviceId es un GUID de enrolamiento generado y persistido, no un ID Entra/MDE inferido. DeviceName queda como atributo de presentación. Un usuario puede trabajar en varios dispositivos y un equipo puede reportar distintas cuentas. La relación con usuarios se guarda en el contexto validado de las ejecuciones y en las proyecciones; no se replica un lote por usuario.

Una credencial con grant de carpeta genera un ámbito de permisos por emisor. La partición por prefijo ayuda a organizar; no elimina límites de ámbitos únicos de SharePoint. La ampliación y partición de bibliotecas/sitios por capacidad se medirán en SP8 antes de comprometer despliegues masivos.

## Identidad y comprobaciones

- Reutiliza aplicación, service principal, certificado y carpeta de la configuración guardada. Un nombre coincidente sin IDs persistidos exige un ID explícito para evitar adopción ambigua.
- Crea certificado RSA en Cert:\CurrentUser\My, no exportable, accesible al usuario de ejecución y SYSTEM. La clave privada permanece en Windows; Entra recibe la parte pública.
- Guarda configuración local en %LOCALAPPDATA%\EndpointMIPScanner\Publisher\publisher.json, con ACL del usuario y SYSTEM. La ruta pública queda en .endpoint-install/publisher-pointer.json.
- Valida las asignaciones de biblioteca: acceso sustantivo solo de administradores del sitio; Limited Access se reconoce por RoleType.Guest. Tras el grant, valida el ámbito del dispositivo con la aplicación esperada.
- Prueba autenticación app-only real, creación de un marcador sintético, descarga y SHA-256 idéntico, y rechazo 403/404 de una carpeta de control conocida sin grant. 401 y fallos de red no cuentan como aislamiento.
- Borra únicamente la carpeta de prueba que creó ese intento; conserva la raíz de registro y control. No sube ni modifica el lote del scanner.
- La prueba con una identidad de usuario final independiente queda pendiente y figura expresamente en el resumen. Los administradores del sitio conservan su acceso.

Para repetir solo la comprobación app-only, desde PS5.1 sin elevación:

```powershell
$result = & '.\LocalMIPScanner.WinPS51\Test-LocalMIPPublisher.ps1'
```

La tarea futura usará la misma cuenta y perfil Windows del registro, sin privilegios máximos. Esta etapa no crea tareas. El GUID de registro corresponde a la cuenta y dispositivo; varias cuentas del mismo equipo pueden tener registros diferentes. No se migran automáticamente certificados anteriores de máquina.

## Evidencia y aceptación

Comparte el bloque magenta PUBLICADOR SHAREPOINT PARA COMPARTIR. Verificar Verified=true, Authentication=CertificateAppOnly, WriteAndDownloadHashVerified=true, UngrantedFolderDenied=true y BatchUploaded=false. EndUserAccessTest permanece PendingSeparateIdentity hasta su prueba específica. La evidencia se guarda en .endpoint-install/publisher-preflight.json.

Las pruebas offline cubren partición, uso de token de aplicación en solicitudes, comparación SHA-256, rechazo de permisos excesivos, diferenciación 401/403/404 y limpieza del marcador propio mediante transporte simulado. El modo Plan se ejecutó con el sitio piloto sin conectar. La creación de apps, consentimiento, registro remoto del certificado, grants y pruebas remotas necesitan ejecución en el tenant.

Referencias: [permisos seleccionados](https://learn.microsoft.com/en-us/graph/permissions-selected-overview), [grant de listItem](https://learn.microsoft.com/en-us/graph/api/listitem-post-permissions?view=graph-rest-1.0), [Limited Access](https://learn.microsoft.com/en-us/sharepoint/understanding-permission-levels).

## Ejecución sin elevación y límite de confianza

Publisher omite Visual C++ y la compilación/pruebas del SDK. Usa PS7 portátil y módulos instalados para el usuario. La autorización administrativa de Microsoft 365 durante el registro es distinta de la elevación local y sigue siendo necesaria.

La cuenta propietaria del certificado puede utilizar la API para modificar sus propios informes dentro de su carpeta. Ocultar la biblioteca y restringir sus permisos de usuario no impide utilizar esa credencial de aplicación. El grant limita el acceso a otras carpetas. Una protección frente al propietario de la credencial requiere un publicador central de confianza. Los hashes verifican la transferencia; no garantizan autenticidad frente al propietario de la credencial.

Validación de esta corrección: Test-Publisher ejecutado en Windows PowerShell 5.1 con token Windows no elevado: creación/uso/eliminación de certificado CurrentUser real; rechazo de cuenta/almacén incorrectos. HTTP, hashes e aislamiento usan transporte simulado. Pasaron el análisis sintáctico de la suite, Test-SuiteLayout y Plan sin conexión. No se ejecutaron registro ni pruebas de permisos contra el tenant.
