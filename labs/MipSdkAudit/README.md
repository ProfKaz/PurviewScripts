# Laboratorio de auditoría con MIP File SDK

Este ejecutable de laboratorio comprueba qué política carga el SDK para una identidad de prueba, qué tipos de información confidencial (SIT) solicita y qué acciones devuelve. Genera un DOCX sintético en una carpeta temporal y lo abre en solo lectura. La segunda pasada puede aportar una coincidencia simulada para un SIT solicitado por el SDK. Ambas pasadas usan el mismo documento para aislar el efecto del resultado que aporta el detector.

El laboratorio se ejecuta por separado de LocalMIPScanner. Usa .NET 10 x64 en Windows, MIP File SDK y MSAL para el inicio de sesión en el navegador. Los paquetes se restauran al compilar este proyecto. El SDK requiere las bibliotecas de Visual C++ x64 indicadas en la [guía de instalación de Microsoft](https://learn.microsoft.com/es-es/information-protection/develop/setup-configure-mip).

## Instalar y verificar

Descarga el instalador en la carpeta desde la que quieras instalar el laboratorio. Usa una sesión dedicada de PowerShell 7.2 o posterior para la instalación y el registro de la aplicación. [Install-MipSdkAudit.ps1](https://github.com/ProfKaz/PurviewScripts/blob/main/Install-MipSdkAudit.ps1)

~~~powershell
$lab = .\Install-MipSdkAudit.ps1 -Destination 'C:\Deploy\LocalMIPScanner'
~~~

El instalador resuelve la revisión en GitHub, verifica los hashes de los archivos y guarda una copia de los archivos locales que vaya a reemplazar. Busca un SDK y runtime .NET 10 x64 en la misma instalación. Si hace falta, descarga el SDK de Microsoft, verifica su SHA-512 y lo instala en una carpeta dedicada del perfil. Usa la ruta del ejecutable encontrado para compilar y ejecutar la prueba sin conexión. Puedes seleccionar un ejecutable concreto con `-DotNetPath`. El instalador devuelve las rutas necesarias para los pasos siguientes.

## Verificación local

El instalador ejecuta esta prueba automáticamente. Para repetirla, usa el mismo ejecutable que seleccionó.

~~~powershell
& $lab.DotNetPath $lab.LabAssembly --self-test
~~~

El resultado esperado incluye `nativeSdkInitialized`, `syntheticCallbackPassed` y `sampleUnchanged` en `true`.

Desde un clon del repositorio con el SDK .NET 10 x64 en el PATH, también puedes usar `dotnet run --project .\labs\MipSdkAudit -c Release -- --self-test`. Si hay varias instalaciones, ejecuta `Get-Command dotnet -All`, `dotnet --list-sdks` y `dotnet --list-runtimes` para identificar cuál está activa. Una instalación que solo muestre el runtime puede ejecutar ensamblados compilados pero necesita un SDK para compilar. [.NET en Windows](https://learn.microsoft.com/en-us/dotnet/core/install/windows#install-with-powershell)

## Preparar el tenant de laboratorio

1. Usa una cuenta miembro de un tenant comercial de prueba. Publica para esa cuenta una política con una regla de clasificación para archivos y un SIT de laboratorio conocido. Configura la regla para aceptar una coincidencia con confianza de 85 y registra qué acción esperas de la política.
2. Ejecuta `New-MipSdkAuditApp.ps1`. El script instala los módulos de Graph necesarios para el usuario actual y pide inicio de sesión en el tenant indicado con el permiso delegado `Application.ReadWrite.All`. Registra o reutiliza una aplicación marcada para este laboratorio, configura `http://localhost` y solicita `UnifiedPolicy.User.Read`. Usa `-IncludeRightsManagement` si también necesitas solicitar `user_impersonation`. El resultado incluye el vínculo a los permisos de la aplicación para revisar el consentimiento requerido por el tenant. El cliente público usa inicio de sesión interactivo y caché en memoria. [Configuración del SDK](https://learn.microsoft.com/es-es/information-protection/develop/setup-configure-mip), [permisos delegados](https://learn.microsoft.com/en-us/information-protection/develop/concept-api-permissions#delegated-permissions)
3. Usa el UPN de la cuenta de prueba. Puedes iniciar con la pasada base y escoger después un SIT solicitado.

~~~powershell
$tenantId = Read-Host 'Id del tenant de laboratorio'
$app = & $lab.AppSetupScript -TenantId $tenantId
$app | Format-List
$testUser = Read-Host 'UPN de la cuenta de prueba'
& $lab.DotNetPath $lab.LabAssembly $app.TenantId $app.ClientId $testUser

$sitId = Read-Host 'Id del SIT de laboratorio que solicitó la política'
& $lab.DotNetPath $lab.LabAssembly $app.TenantId $app.ClientId $testUser $sitId
~~~

El navegador solicita inicio de sesión. Si el SDK pide consentimiento para conectarse a un servicio, el laboratorio muestra el host en la consola.

Si ya registraste la aplicación manualmente, puedes pasar sus identificadores al laboratorio. El script reutiliza sus propios registros cuando coinciden la configuración y los permisos. Usa `-WhatIf` para revisar la intención sin conectar a Graph. El consentimiento se gestiona en Entra y la política de Purview se publica por separado.

## Interpretar el resultado

| Evento | Qué comprobar |
| --- | --- |
| `policy` | `hasClassificationRules` indica si la identidad recibió reglas. `rulePackageCount` cuenta paquetes de reglas cargados. |
| `classification` | Compara las solicitudes y acciones en `baseline` y `simulatedMatch`. `simulatedMatchSupplied` confirma que el SDK solicitó el SIT elegido y recibió el resultado simulado. |
| `integrity` | `sampleUnchanged = true` confirma que el hash y la fecha de escritura del documento sintético coinciden antes y después. |
| `error` | Incluye la etapa y la clase del error y, si procede, el código de autenticación. |

Si el SDK no solicita el SIT elegido, revisa que la política se haya publicado para esa cuenta y que la regla se aplique al formato. Un arreglo vacío de acciones registra lo que devolvió el SDK en esa pasada. La coincidencia simulada comprueba la conexión con la política. La extracción y detección del documento se validan por separado en el piloto local. El laboratorio invoca `ClassifyAsync` para observar acciones y deshabilita la auditoría de descubrimiento del archivo. El SDK puede emitir telemetría mínima. [IFileHandler](https://learn.microsoft.com/en-us/dotnet/api/microsoft.informationprotection.file.ifilehandler?view=mipsdk-dotnet-1.18), [FileExecutionState](https://learn.microsoft.com/en-us/dotnet/api/microsoft.informationprotection.file.fileexecutionstate?view=mipsdk-dotnet-1.18)

La salida omite tokens, UPN, XML de políticas y valores del documento. Antes de compartirla, revisa los identificadores de SIT y paquetes de reglas. La comparación posterior con `Set-FileLabel -AutoLabel` se hace sobre copias desechables porque ese comando puede escribir etiquetas. [Set-FileLabel](https://learn.microsoft.com/en-us/powershell/module/purviewinformationprotection/set-filelabel?view=azureipps)
