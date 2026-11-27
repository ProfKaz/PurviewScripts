# Endpoint MIP Scanner

Suite 1.4.6 disponible. Web part 0.13.2 verificado en el piloto. Consultar el [registro de pruebas y límites](ScannerPortal/docs/PILOT-EVIDENCE.md) y los [comandos de diagnóstico](ScannerPortal/docs/PILOT-TROUBLESHOOTING.md).

## Instalación única

Descarga únicamente **Install-EndpointMIPScanner.ps1**, guárdalo en **C:\Deploy\Endpoint MIP Scanner** y abre Windows PowerShell 5.1 x64.

```powershell
Set-Location 'C:\Deploy\Endpoint MIP Scanner'
Unblock-File -LiteralPath '.\Install-EndpointMIPScanner.ps1'
.\Install-EndpointMIPScanner.ps1 -Ref main
```

Antes del merge, usa `-Ref feat/endpoint-unified-installer`. El instalador fija un SHA para todos los componentes, descarga y verifica la carpeta completa y prepara los componentes locales. Conserva los Config existentes y deja las versiones de distribución modificadas con sufijo .distribution. Respalda los archivos de código reemplazados. No borra instalaciones anteriores: usa la carpeta nueva para este cambio de estructura.

| Etapa | Acción |
| --- | --- |
| Download | Descarga verificada de toda la suite, incluidos instaladores internos, scripts y logo. |
| Local (predeterminada) | Download, Visual C++ x64 si falta, SDK .NET 10 x64, compilación/autodiagnóstico del lab y prueba rápida del estado del scanner. |
| MipApp | Local y creación/reutilización de la app MIP, con logo local y login administrativo. |
| Portal | Local y preparación administrativa de PS7.6.0/PnP3.2.0/Graph, app del portal con logo y sitio/bibliotecas/listas piloto. |
| Publisher | Preparación del publicador para un sitio existente, certificado CurrentUser y grant por carpeta de registro. Sin elevación local; requiere autorización administrativa Entra/SharePoint durante el registro. Omite instalar/compilar el SDK. |
| ControlPlane | Prepara la app de aplicación/certificados del portal, aprueba solicitudes públicas y publica/asigna perfiles. No instala SDK. |
| ManagedEndpoint | Enrola la cuenta/equipo sin elevación; opcionalmente registra tarea Limited después de comprobar token y perfil. No instala SDK. |
| All | Local, MipApp y Portal en orden. Solicita los datos faltantes en consola. |

```powershell
.\Install-EndpointMIPScanner.ps1 -Ref main -Stage All
```

Puedes reutilizar explícitamente las apps con -TenantId, -MipClientId y -PortalClientId, y proporcionar -AdminUrl, -SiteUrl y -Owner. Los IDs se guardan y se reutilizan en la misma instalación. Si una app de portal existe pero no hay ID guardado, se pide su ID explícito antes de adoptarla. La etapa Portal aprovisiona una base vacía; la ingesta y el portal SPFx siguen siendo hitos pendientes.

La etapa Portal requiere una cuenta administradora autorizada y consentimiento a los permisos de instalación. Para un sitio existente revisa primero sus permisos; -ResumeFoundation retoma únicamente el piloto esperado, usando las comprobaciones del instalador original. La identidad administrativa con AllSites.FullControl se destina al aprovisionamiento, no al futuro publicador de informes.

Los componentes nativos pueden requerir elevación y reinicio al instalar Visual C++. No se cambia la versión del cliente Purview ya instalada. Ese cliente y sus cmdlets son un control independiente de la biblioteca Microsoft.InformationProtection.File 1.18.148 del laboratorio.

## Estructura

- LocalMIPScanner.WinPS51: scanner y pruebas activas.
- LocalMIPScanner.WinPS7[Pending]: edición anterior pendiente; se descarga como referencia.
- labs/MipSdkAudit: una sola fuente C# y script de registro compatible con PS5.1.
- ScannerPortal: portal, contratos y despliegue.
- deployment: instaladores auxiliares invocados por el instalador único.
- suite-manifest.json: versión, ID de seguimiento por script y dependencias.

## Evidencia y siguientes pruebas

.endpoint-install contiene files.json (commit y Git blob hashes), status.json (pasos completados y errores), dependencies.json (motores/módulos/scripts), lab.json y los IDs públicos de las apps cuando se preparan. El GUID de seguimiento identifica el script, InstallId identifica un intento y Commit identifica el código exacto. No se guardan tokens ni claves privadas.

Los encabezados PSScriptInfo incluyen VERSION, GUID, AUTHOR y RELEASE NOTES; HISTORY conserva las entradas posteriores sin cambiar el GUID. El formato sigue el ejemplo MPARR2. Al modificar un script, incrementar su versión e historial y actualizar suite-manifest.json.

Las pruebas del scanner se ejecutan desde LocalMIPScanner.WinPS51. Recupera las rutas del lab con `Get-Content .\.endpoint-install\lab.json -Raw | ConvertFrom-Json`. El aprovisionamiento Entra/SharePoint y la llegada de eventos se validan en el tenant; el instalador no los da por probados al descargar archivos.

[Plan M1–M5](LocalMIPScanner.WinPS51/README.md) · [Plan integral SharePoint](ScannerPortal/docs/END-TO-END-TEST-PLAN.md) · [Milestones](ScannerPortal/docs/MILESTONES.md)

## Permisos y carpetas por dispositivo

La [preparación del publicador](ScannerPortal/docs/PUBLISHER-PREFLIGHT.md) usa el sitio existente y conserva el lote real pendiente mientras valida autenticación app-only, escritura/lectura con hash y aislamiento de carpeta.

La administración central y el envío verificado del piloto se detallan en [Endpoints administrados](ScannerPortal/docs/MANAGED-ENDPOINTS.md). Las etapas nuevas son explícitas y no forman parte de All. No implican que ya exista un editor SPFx o un procesador central de aceptación.
