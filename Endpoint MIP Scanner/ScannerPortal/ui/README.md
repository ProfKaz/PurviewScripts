# Reporte interactivo del portal (W07B)

Web part de solo lectura para una página moderna de ScannerPortalPilot.
SPFx 1.24.1, React 18.3.1 y Fluent UI. Los recursos del cliente se empaquetan
en SharePoint. El paquete se instala en el sitio piloto y no solicita permisos
adicionales de API. La lectura REST usa la sesión del usuario y la lista de
aceptaciones del sitio actual. El certificado del publicador no interviene.

Con Node.js 24 y npm, desde esta carpeta:

```powershell
npm ci
node --test test/report.test.mjs
npm run build
```

El paquete queda en sharepoint/solution/scanner-report.sppkg. Cárgalo en un
catálogo de aplicaciones de SharePoint autorizado y agrega la aplicación
solo al sitio piloto. Antes de agregar el web part, verifica que la página
administrativa esté restringida. La página estática W07A sirve como referencia
y puede quedar disponible durante la validación.

En la página, agrega **Endpoint MIP Scanner · Reporte**. Configura el GUID
de ScannerPortalAcceptance y el ID de aceptación 1. Para el piloto,
el GUID es ef8d5b7c-9550-4fb5-b704-034924b903be.

Verifica 2293 archivos, 1814 con respuesta, 479 sin respuesta, 98 tipos
detectados y 13 errores de cobertura. Abre Tipos detectados, busca
Credit Card Number y cambia entre los órdenes por archivos, coincidencias
y nombre. Limpia la búsqueda para verificar que vuelvan los 98 tipos.
Una prueba con una cuenta ordinaria debe comprobar la página y el acceso
directo al registro de SharePoint.

Referencias: Microsoft Learn SPFx 1.24.1 y GoogleChrome Modern Web Guidance.

## Install the packaged pilot

Run deployment/Install-ScannerPortalReport.ps1 using PowerShell 7.4+ and
PnP.PowerShell 3.2.0 (the pilot runtime already supplies PowerShell).
The script fetches a pinned package from GitHub and verifies SHA-256 before
using the existing Setup app for the one-time interactive administrator
sign-in. DownloadOnly downloads and verifies without requiring PnP.
The site collection App Catalog must already be enabled. The script uploads
and installs at Site scope, verifies the version, and reuses an existing
installation of that version. An upgrade needs a separate deployment.
Portal viewers do not run this installer or install Node, npm, or PowerShell.
Placement and configuration of the web part on the protected page follow
installation.
