> Instalación 1.1.0: usa el [instalador único de la suite](../README.md). Los comandos de instaladores separados de versiones anteriores quedan sustituidos por esa entrada.

# LocalMIPScanner para Windows PowerShell 5.1

Edición de prueba de M1–M5 para Windows PowerShell 5.1 de 64 bits. El estado y los registros se crean bajo `%LOCALAPPDATA%\LocalMIPScanner.WinPS51`. Usa un directorio de despliegue nuevo y una raíz de datos exclusiva. No copies el índice ni el journal de otro piloto.

| Hito | Validación |
| --- | --- |
| M1 | Inventario de metadatos, exclusiones, errores, junctions y archivos sin modificar. |
| M2 / M2.1 | Cambios, reutilización, checkpoints, interrupción, consolidación y restauración desde backup. |
| M3 | Auditoría TXT/CSV explícita, reutilización de resultados y evaluación de hallazgos mapeados con el SDK. |
| M4 | Etiqueta sin protección aplicada a una copia de Word, Excel o PowerPoint y verificada en disco. |
| M5 | Mediciones separadas de inventario, auditoría local, autodiagnóstico y evaluación de política. |

## Preparación

Ejecuta primero el [instalador único](../README.md) desde Windows PowerShell 5.1 x64. El directorio de referencia es C:\Deploy\Endpoint MIP Scanner. Luego ejecuta la batería desde la subcarpeta del scanner.

```powershell
Set-Location 'C:\Deploy\Endpoint MIP Scanner\LocalMIPScanner.WinPS51'
foreach ($test in Get-ChildItem .\tests\Test-*.ps1 | Sort-Object Name) {
    & (Join-Path $PSHOME 'powershell.exe') -NoProfile -File $test.FullName
    if ($LASTEXITCODE -ne 0) { throw "Failed: $($test.Name)" }
}
```

## SDK y cuenta

PowerShell 5.1 inicia el laboratorio como proceso externo. El laboratorio conserva .NET 10 x64 y MIP File SDK 1.18.148. El módulo del cliente Purview 3.2.92.0 es un control independiente. Su instalación no cambia la biblioteca que usa el laboratorio. El inventario y la auditoría local se pueden probar antes de instalar .NET.

```powershell
$lab = Get-Content -LiteralPath '..\.endpoint-install\lab.json' -Raw | ConvertFrom-Json
$sdk = @{ DotNetPath = $lab.DotNetPath; LabAssembly = $lab.LabAssembly }
.\Measure-LocalMIPScanner.ps1 -Scenario SdkSelfTest @sdk
```

Reutiliza una aplicación existente del piloto con consentimiento y WAM. Copia `policy-audit.json` a una carpeta de trabajo y ajusta `roots` para que apunte a una carpeta de archivos de prueba, por ejemplo `C:\Deploy\LocalMIPScanner.WinPS51-Pilot\Documents`. Escribe el JSON como UTF-8 sin BOM si lo generas desde 5.1: `[IO.File]::WriteAllText($path, $json, [Text.UTF8Encoding]::new($false))`. El script opcional de registro de Entra está incluido; requiere los módulos de Microsoft Graph y una cuenta autorizada. La prueba normal reutiliza la aplicación y no llama al script de registro.

```powershell
$policyConfig = 'C:\Deploy\LocalMIPScanner.WinPS51-Pilot\policy-audit.json'
$root = @( (Get-Content -LiteralPath $policyConfig -Raw | ConvertFrom-Json).roots )[0]
& $lab.DotNetPath $lab.LabAssembly --check-sso $policyConfig
if ($LASTEXITCODE -ne 0) { throw 'SSO failed' }
```

## Secuencia manual

1. Copia archivos sintéticos a la raíz piloto. Ejecuta `.\Invoke-LocalMIPScanner.ps1 -Root $root` dos veces. Verifica que la segunda pasada reutilice los metadatos. Cambia un archivo y confirma el delta. Usa `-MaxDirectories 1` y reanuda con la misma raíz y configuración para probar el checkpoint en un árbol con subcarpetas.
2. Incluye un TXT con una coincidencia sintética de la regla local declarada en `policy-audit.json`. Ejecuta `.\Measure-LocalMIPScanner.ps1 -Scenario ContentAudit -Root $root -RunCount 2`. Comprueba análisis y reutilización. Usa el `logFile` del resumen de la primera pasada para `.\Measure-LocalMIPScanner.ps1 -Scenario PolicyAudit -PolicyConfig $policyConfig -AuditLog $auditLog @sdk -RunCount 2`. Confirma que el SDK evaluó al menos un candidato.
3. Lista las etiquetas con `& $lab.DotNetPath $lab.LabAssembly --list-office-labels $policyConfig`. Selecciona una con `addsProtection=false`. Ejecuta `--apply-office-copy $policyConfig $source $output $labelId` con el mismo ejecutable y DLL. Repite para DOCX, XLSX y PPTX limpios, usando un destino nuevo con la misma extensión. Verifica `verified=true` y `sourceUnchanged=true`.
4. Mide inventario con `.\Measure-LocalMIPScanner.ps1 -Scenario Inventory -Root $root -RunCount 2`. Conserva los `metrics.json` y compara tiempo efectivo de CPU, duración, memoria y contadores de trabajo.
5. Después de M1–M5, ejecuta el piloto de [Activity Explorer](../labs/MipSdkAudit/ACTIVITY-PILOT.md) en la misma sesión, con una copia nueva. Busca por la hora UTC y el nombre del archivo. Haz el control del módulo Purview con otro archivo equivalente. Conserva el detalle de Purview Audit si el export de Activity Explorer no trae aplicación o proceso.

## Dependencias y trazabilidad

| Componente | Requisito y evidencia |
| --- | --- |
| Instalador único | Windows PowerShell 5.1 x64 y acceso HTTPS a la API de GitHub y a `raw.githubusercontent.com`. Resuelven la referencia a un SHA y verifican los archivos descargados contra el árbol de Git. |
| Inventario y auditoría local | El instalador del scanner descarga configuración, módulos, pruebas y `WinPSCompatibility.ps1`. El runtime usa .NET Framework incluido en Windows. La lista de archivos y hashes queda en `.localmipscanner-winps51-install.json`. |
| Laboratorio | El instalador del SDK descarga el código del laboratorio. Usa un SDK .NET 10 x64 indicado por `-DotNetPath`, una instalación compatible detectada, o descarga una copia verificada desde Microsoft. La compilación restaura los paquetes de NuGet declarados en `labs/MipSdkAudit/MipSdkAudit.csproj`. Registra `SourceCommit`, `DotNetPath`, `LabAssembly` y `SelfTestPassed`. |
| Pruebas con el tenant | La prueba autenticada usa Windows WAM, la configuración del piloto y una aplicación Entra autorizada. Los módulos Microsoft Graph solo se necesitan al ejecutar el script opcional de registro de la aplicación. El cliente Purview con `Get-FileStatus` y `Set-FileLabel` se usa como control independiente en M6. |

## Informes locales

El [consolidador de lotes](REPORT-BATCHES.md) incorpora los resultados del descubrimiento amplio y sus reintentos, verifica la cobertura y genera un lote PendingUpload con hashes para la siguiente prueba de entrega.
