# Scanner Portal para SharePoint Online

Portal unificado de configuración, descubrimiento y actividades del scanner oficial de Microsoft Purview y de Local MIP Scanner. Experiencia inspirada en Purview, con identidad propia; no es un portal oficial de Microsoft.

## Estado de esta entrega

10 de noviembre de 2026. **SP0 completado: diagnóstico y arquitectura. SP1 iniciado: contratos y filtrado de referencia con pruebas offline.** No hay todavía un paquete SPFx ni un portal desplegado. No se modificaron la instalación local ni la tarea de Activity Explorer en ejecución.

| Documento | Propósito |
| --- | --- |
| [Arquitectura](docs/ARCHITECTURE.md) | Componentes, almacenamiento, seguridad y permisos |
| [Diagnóstico](docs/DISCOVERY.md) | Hallazgos verificados y riesgos de integración |
| [Milestones](docs/MILESTONES.md) | Secuencia, dependencias y criterios de aceptación |
| [Contratos](docs/CONTRACTS.md) | Configuración, eventos y publicación |
| [Decisiones](docs/DECISIONS.md) | Decisiones arquitectónicas y asuntos pendientes |
| [Operación](docs/RUNBOOK.md) | Instalación prevista, recuperación y validación |
| [Preparación del piloto](docs/PILOT-SETUP.md) | Plan offline y creación autenticada de un sitio vacío |

## Base ejecutable

`src/ScannerPortal.Activity.psm1` construye consultas de Activity Explorer con identidad obligatoria y filtra registros por coincidencia exacta. Es un componente de integración, **todavía no conectado al exportador productivo**. Las pruebas usan datos sintéticos y no requieren Microsoft 365:

```powershell
pwsh -NoProfile -File ./ScannerPortal/tests/Test-ActivityScope.ps1
```

`config/scanner-profile.example.json` es un contrato ilustrativo sin secretos. No debe entregarse directamente al scanner: el adaptador de SP2 lo materializará en los cinco archivos que consume actualmente. `deployment/solution-manifest.json` describe los recursos previstos; aún no los aprovisiona.

`deployment/New-ScannerPortalPilot.ps1` permite preparar el plan y, con `-Mode Apply`, crear el sitio piloto mediante PnP y login de Microsoft. Es solo la fase de sitio: no aprovisiona listas ni despliega SPFx. Ver [preparación del piloto](docs/PILOT-SETUP.md).

`deployment/Register-ScannerPortalSetupApp.ps1` prepara o registra una aplicación interactiva dedicada por tenant, sin secreto de cliente. El código es reutilizable; cada instalación conserva su propio Client ID público. Ver también [identidad Kaz Demos](docs/BRANDING.md).

## Reglas del proyecto

- Todo el seguimiento de esta solución vive en esta carpeta y en los issues que la referencien.
- Una configuración oculta requiere ACL; `Hidden=true` es solamente presentación.
- No guardar secretos, tokens, PFX, datos detectados ni exportaciones reales en GitHub.
- El éxito de exportación requiere publicación completa; el checkpoint se confirma después.
- Cada resultado conserva su procedencia. Las reglas locales no se presentan como SIT oficiales equivalentes sin validación.
- Los milestones del portal usan prefijo `SP` para no confundirse con M0–M6 del scanner.
