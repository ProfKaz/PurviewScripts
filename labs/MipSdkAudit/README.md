# Laboratorio de auditoría con MIP File SDK

Este ejecutable de laboratorio comprueba qué política carga el SDK para una identidad de prueba, qué tipos de información confidencial (SIT) solicita y qué acciones devuelve. Genera un DOCX sintético en una carpeta temporal y lo abre en solo lectura. La segunda pasada puede aportar una coincidencia simulada para un SIT solicitado por el SDK. Ambas pasadas usan el mismo documento para aislar el efecto del resultado que aporta el detector.

El laboratorio se ejecuta por separado de LocalMIPScanner. Usa .NET 8 x64 en Windows, MIP File SDK y MSAL para el inicio de sesión en el navegador. Los paquetes se restauran al compilar este proyecto. El SDK requiere las bibliotecas de Visual C++ x64 indicadas en la [guía de instalación de Microsoft](https://learn.microsoft.com/es-es/information-protection/develop/setup-configure-mip).

## Verificación local

Desde la raíz del repositorio, ejecuta lo siguiente. Inicializa el SDK en modo sin conexión y comprueba el callback con solicitudes sintéticas y la integridad del DOCX.

~~~powershell
dotnet run --project .\labs\MipSdkAudit -c Release -- --self-test
~~~

El resultado esperado incluye `nativeSdkInitialized`, `syntheticCallbackPassed` y `sampleUnchanged` en `true`.

## Preparar el tenant de laboratorio

1. Usa una cuenta miembro de un tenant comercial de prueba. Publica para esa cuenta una política con una regla de clasificación para archivos y un SIT de laboratorio conocido. Configura la regla para aceptar una coincidencia con confianza de 85 y registra qué acción esperas de la política.
2. Registra una aplicación de un solo tenant en Microsoft Entra. Agrega la plataforma **Aplicaciones móviles y de escritorio** con la URI de redirección `http://localhost`. Concede a la aplicación el permiso delegado `UnifiedPolicy.User.Read` de **Microsoft Purview Information Protection Sync Service**. Si el SDK solicita autenticación con Azure Rights Management, configura también el permiso delegado `user_impersonation` según el procedimiento de Microsoft. Aplica el consentimiento que requiera el tenant. [Configuración del SDK](https://learn.microsoft.com/es-es/information-protection/develop/setup-configure-mip), [permisos delegados](https://learn.microsoft.com/en-us/information-protection/develop/concept-api-permissions#delegated-permissions)
3. Obtén el identificador del tenant, el identificador de la aplicación y el UPN de la cuenta de prueba. El laboratorio usa autenticación interactiva y caché en memoria. Puedes iniciar con la pasada base y escoger después un SIT solicitado.

~~~powershell
$tenantId = Read-Host 'Id del tenant de laboratorio'
$clientId = Read-Host 'Id de la aplicación de laboratorio'
$testUser = Read-Host 'UPN de la cuenta de prueba'
dotnet run --project .\labs\MipSdkAudit -c Release -- $tenantId $clientId $testUser

$sitId = Read-Host 'Id del SIT de laboratorio que solicitó la política'
dotnet run --project .\labs\MipSdkAudit -c Release -- $tenantId $clientId $testUser $sitId
~~~

El navegador solicita inicio de sesión. Si el SDK pide consentimiento para conectarse a un servicio, el laboratorio muestra el host en la consola.

## Interpretar el resultado

| Evento | Qué comprobar |
| --- | --- |
| `policy` | `hasClassificationRules` indica si la identidad recibió reglas. `rulePackageCount` cuenta paquetes de reglas cargados. |
| `classification` | Compara las solicitudes y acciones en `baseline` y `simulatedMatch`. `simulatedMatchSupplied` confirma que el SDK solicitó el SIT elegido y recibió el resultado simulado. |
| `integrity` | `sampleUnchanged = true` confirma que el hash y la fecha de escritura del documento sintético coinciden antes y después. |
| `error` | Incluye la etapa y la clase del error y, si procede, el código de autenticación. |

Si el SDK no solicita el SIT elegido, revisa que la política se haya publicado para esa cuenta y que la regla se aplique al formato. Un arreglo vacío de acciones registra lo que devolvió el SDK en esa pasada. La coincidencia simulada comprueba la conexión con la política. La extracción y detección del documento se validan por separado en el piloto local. El laboratorio invoca `ClassifyAsync` para observar acciones y deshabilita la auditoría de descubrimiento del archivo. El SDK puede emitir telemetría mínima. [IFileHandler](https://learn.microsoft.com/en-us/dotnet/api/microsoft.informationprotection.file.ifilehandler?view=mipsdk-dotnet-1.18), [FileExecutionState](https://learn.microsoft.com/en-us/dotnet/api/microsoft.informationprotection.file.fileexecutionstate?view=mipsdk-dotnet-1.18)

La salida omite tokens, UPN, XML de políticas y valores del documento. Antes de compartirla, revisa los identificadores de SIT y paquetes de reglas. La comparación posterior con `Set-FileLabel -AutoLabel` se hace sobre copias desechables porque ese comando puede escribir etiquetas. [Set-FileLabel](https://learn.microsoft.com/en-us/powershell/module/purviewinformationprotection/set-filelabel?view=azureipps)
