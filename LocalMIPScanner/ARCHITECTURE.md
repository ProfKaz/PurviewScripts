# Arquitectura y plan de trabajo

## Revisión del script de partida

El PowerShell adjunto recorre C:\ cuatro veces para PDF y patrones de Word, Excel y PowerPoint. Consulta Get-FileStatus y aplica la misma etiqueta a los archivos sin etiqueta mediante Set-FileLabel -PreserveFileDetails. La etiqueta está fijada al entorno original. El modificador conserva la fecha de modificación, de modo que esa fecha por sí sola no sirve para detectar un cambio de etiqueta.

El script también intenta registrar una tarea diaria a las 14:00 con S4U. El valor Highes de RunLevel tiene un error tipográfico y la acción pasa un bloque de comandos directamente como argumentos de powershell.exe. Para un piloto de automatización conviene invocar un archivo con -File y comprobar la identidad efectiva, los permisos y la autenticación no interactiva. La revisión del adjunto fue estática. [Get-FileStatus](https://learn.microsoft.com/en-us/powershell/module/purviewinformationprotection/get-filestatus?view=azureipps), [Set-FileLabel](https://learn.microsoft.com/en-us/powershell/module/purviewinformationprotection/set-filelabel?view=azureipps), [Set-Authentication](https://learn.microsoft.com/en-us/powershell/module/purviewinformationprotection/set-authentication?view=azureipps).

## Superficies de integración de Microsoft

Revisión documental del 9 de noviembre de 2026.

| Superficie | Capacidad y límite para este proyecto |
| --- | --- |
| Purview Information Protection Scanner | El escáner oficial se instala en Windows Server con SQL Server y usa IFilter de Windows para inspeccionar formatos compatibles. Sirve de referencia para separar descubrimiento, extracción y etiquetado. [Funcionamiento](https://learn.microsoft.com/en-us/purview/deploy-scanner), [instalación](https://learn.microsoft.com/en-us/purview/deploy-scanner-configure-install). |
| MIP File SDK | La rama 1.18 está soportada y el historial lista 1.18.148. El File SDK permite consultar etiquetas y protección y aplicar cambios según el formato. ClassifyAsync evalúa reglas del motor y devuelve acciones, LoadSensitivityTypes solicita los tipos con la directiva y FileExecutionState expone un callback de resultados de clasificación. Estas interfaces requieren una prueba de concepto para determinar qué detectores, resultados y formatos están disponibles para una aplicación de terceros bajo la identidad y directiva del tenant. [Versiones](https://learn.microsoft.com/en-us/information-protection/develop/version-release-history), [IFileHandler](https://learn.microsoft.com/en-us/dotnet/api/microsoft.informationprotection.file.ifilehandler?view=mipsdk-dotnet-1.18), [LoadSensitivityTypes](https://learn.microsoft.com/en-us/dotnet/api/microsoft.informationprotection.file.fileenginesettings.loadsensitivitytypes?view=mipsdk-dotnet-1.18), [FileExecutionState](https://learn.microsoft.com/en-us/dotnet/api/microsoft.informationprotection.file.fileexecutionstate?view=mipsdk-dotnet-1.18). |
| Caché MIP y Endpoint DLP | Microsoft describe la caché del SDK para directivas, reglas de sensibilidad y licencias, incluida una modalidad cifrada. Es el estado de la aplicación que usa el SDK. En Endpoint DLP, la clasificación avanzada envía contenido al servicio de nube y devuelve resultados al equipo. EDM, entidades con nombre, clasificadores entrenables y credenciales dependen de esa capacidad en Endpoint DLP. La documentación consultada no identifica una API pública compatible para leer o reutilizar el almacén interno del agente desde otro proceso. Se descarta esa dependencia para el diseño inicial. [Caché del SDK](https://learn.microsoft.com/en-us/information-protection/develop/concept-cache-storage), [clasificación avanzada](https://learn.microsoft.com/en-us/purview/dlp-configure-endpoint-settings#advanced-classification-scanning-and-protection), [funcionamiento sin conexión](https://learn.microsoft.com/en-us/purview/endpoint-dlp-learn-about#endpoint-dlp-and-offline-devices). |
| Paquetes de tipos de información confidencial (SIT) | Security & Compliance PowerShell documenta la exportación administrativa de XML con Get-DlpSensitiveInformationTypeRulePackage y SerializedClassificationRuleCollection. Esto permite estudiar una importación controlada de patrones y diccionarios compatibles. El XML de reglas no entrega el motor de Purview, los modelos entrenados ni los valores de referencia de EDM. Validar funciones, proximidad, niveles de confianza y diferencias entre los resultados de ambos motores. [Exportación de reglas](https://learn.microsoft.com/en-us/purview/sit-customize-a-built-in-sensitive-information-type), [paquete EDM](https://learn.microsoft.com/en-us/purview/sit-get-started-exact-data-match-create-rule-package). |
| Clasificación bajo demanda para endpoints | Purview documenta estimación y clasificación de archivos en reposo en Windows incorporados a Endpoint DLP. El administrador puede seleccionar hasta 50 SIT o clasificadores entrenables y revisar resultados en el portal. La clasificación bajo demanda por sí sola no aplica etiquetas. Conviene probarla como referencia de cobertura en equipos administrados. [Clasificación bajo demanda para endpoints](https://learn.microsoft.com/en-us/purview/on-demand-classification-endpoints). |

El cliente Purview para Windows también documenta Set-FileLabel -AutoLabel. Probarlo en un tenant con archivos sintéticos para conocer la cobertura efectiva y el efecto de la directiva. El comando puede escribir etiquetas y queda fuera de la auditoría inicial. [Cmdlet y ejemplos](https://learn.microsoft.com/en-us/powershell/module/purviewinformationprotection/set-filelabel?view=azureipps).

## Diseño modular

Flujo propuesto: configuración → descubrimiento → decisión incremental → extracción y detección → decisión de etiqueta → escritura opcional. El estado local y el registro de eventos acompañan cada etapa. M1 implementa configuración, descubrimiento y registro.

- **Descubrimiento.** PowerShell orquesta y .NET enumera. El inventario emite una entrada por archivo elegible sin abrir su contenido. La lista de extensiones para inventario es independiente de las capacidades de extracción y etiquetado.
- **Índice.** Evaluar SQLite embebido en el perfil local, con una única instancia escritora y transacciones breves. Registrar identidad del archivo si el volumen la expone, ruta, tamaño, última escritura UTC, versión de reglas/extractor, resultado y fecha de la última clasificación exitosa. Releer contenido si el archivo cambió, cambió la configuración relevante o venció el plazo, inicialmente 30 días. Los errores quedan pendientes de reintento. Para cambios que conserven tamaño y fecha, evaluar huella selectiva o señales del sistema de archivos. Mantener el estado separado del documento evita reescribir firmas, propiedades o fechas.
- **Extracción y detección.** Empezar con TXT/CSV y continuar con OOXML y PDF mediante extractores con límites de tamaño y tiempo. Proponer Config/classifiers.json con identificador, versión, activación, expresión regular, palabras de contexto y validador opcional. Versionar el subconjunto de reglas admitido. Registrar identificadores y recuentos de coincidencias sin copiar valores detectados. Medir precisión con ejemplos sintéticos positivos y negativos antes de asignar etiquetas.
- **Etiquetado.** Adaptador separado en C# con Microsoft.InformationProtection.File y autenticación de Microsoft Entra. Comprobar política publicada, etiqueta y protección actuales, soporte del formato y cambios desde la inspección. En el piloto, simular la decisión y exigir activación explícita para escribir. Validar archivos firmados, protegidos, en uso y operaciones que cambien la extensión. [Configuración del SDK](https://learn.microsoft.com/en-us/information-protection/develop/setup-configure-mip), [formatos compatibles](https://learn.microsoft.com/en-us/information-protection/develop/concept-supported-filetypes).
- **Operación.** Mantener registros por ejecución y resúmenes de rendimiento. Medir tiempo, CPU, memoria máxima e I/O en frío y en caliente. Ajustar pausas, límites de archivo y concurrencia a partir de esas mediciones. Para despliegue, definir la cuenta de mínimo privilegio, una ventana de ejecución, exclusión mutua y rotación de registros.

## Hitos y criterios de aceptación

| Hito | Entrega | Prueba de salida |
| --- | --- | --- |
| M0 | Revisión del adjunto e investigación de las interfaces de Microsoft | Documentar las capacidades confirmadas y las preguntas pendientes del tenant. |
| M1 | Inventario configurable de solo lectura con registros locales | Omitir exclusiones, continuar ante errores y verificar la integridad de los archivos. |
| M2 | Índice local y reescaneo incremental | Una segunda ejecución reutiliza resultados. Cambios, expiración y fallos vuelven a habilitar el análisis. Una interrupción conserva el último estado confirmado. |
| M3 | Detección de contenido configurable | Medir falsos positivos y negativos con un corpus sintético por regla y por formato. Probar el SDK y -AutoLabel en un tenant de laboratorio. |
| M4 | Integración MIP | Validar la decisión en auditoría y, con escritura habilitada en el laboratorio, aplicar y verificar etiquetas según política y formato. |
| M5 | Optimización | Medir impacto con una muestra representativa y fijar límites operativos de CPU, memoria e I/O. |
| M6 | Operación | Validar la identidad de la tarea programada, la recuperación tras interrupciones y la retención de registros. |

## Estado incremental M2.1

M2.1 usa PowerShell 7.2+ y .NET para el estado local. Con incremental desactivado, M1 conserva el descubrimiento de metadatos y los eventos de auditoría. M2.1 escribe exclusivamente estado y logs del scanner.

| Archivo | Contenido |
| --- | --- |
| `inventory.index.jsonl` | Cabecera con versión y generación, registros de archivo, y pie end con recuento y SHA-256 de las líneas anteriores. |
| `inventory.active.jsonl` | Cabecera con generación objetivo, generación base y huella del alcance. Guarda secuencias begin, child, seen, protect y checkpoint, y termina con end al completar la cola. |
| `inventory.index.backup` | Única copia rotativa validada de la generación anterior. |
| `inventory.index.tmp` e `inventory.copy.tmp` | Archivos temporales en el mismo directorio para preparar un índice, iniciar un journal o publicar una copia. |
| `inventory.lock` | Bloqueo exclusivo por carpeta de estado. El sistema libera el descriptor si se termina el proceso. |
| `inventory-state.jsonl` | Índice M2 legado, leído durante la migración inicial y conservado para compatibilidad. |

### Recorrido y checkpoints

Las raíces normalizadas inicializan la pila. Cada directorio añade al journal los hijos elegibles y las observaciones de archivos. Los archivos sin cambios emiten seen sin repetir sus metadatos. Si se actualizan los metadatos, seen incluye la entrada nueva. lastDiscoveredUtc corresponde a la observación que generó la entrada vigente. Los puntos de reanálisis y los directorios offline se protegen como prefijos, mientras que los archivos offline o demasiado grandes se contabilizan como observados. Los errores de lectura se registran y el checkpoint marca el directorio como incompleto para efectos de borrado.

Un checkpoint incluye una huella de las líneas del directorio y su indicador de error. Tras vaciar los buffers del journal a disco, se aplican las observaciones a la vista de trabajo y se incorporan los hijos a la pila. Al abrir el estado, se reconstruye la pila desde el journal. Se descarta la última línea si carece de salto LF. Los registros de un directorio sin checkpoint se ignoran y el recorrido vuelve a empezar en ese directorio. Los registros completos inválidos o los checksums incorrectos detienen la reanudación. Los cambios posteriores al checkpoint de un directorio se detectan en la siguiente generación.

Los candidatos a eliminación son entradas elegibles del alcance actual que no se observaron durante una generación completa. Se preservan entradas fuera de alcance, excluidas o bajo un prefijo protegido. Un solo error en cualquier segmento de la generación suspende todas las eliminaciones de esa generación. La siguiente vuelta reintenta el recorrido.

### Publicación y recuperación

1. Con la cola vacía, escribir end con la generación y vaciar el journal a disco.
2. Construir y vaciar el nuevo índice temporal. Leerlo de nuevo para validar estructura, recuento y checksum.
3. Copiar el índice confirmado a un temporal, validar la copia y renombrarla sobre el único backup.
4. Renombrar el índice temporal sobre el principal dentro del mismo volumen. Retirar el journal después de publicar el índice.

| Interrupción | Siguiente arranque |
| --- | --- |
| Antes del checkpoint | Volver al directorio pendiente e ignorar sus observaciones no confirmadas. |
| Después de end y antes de publicar | Reconstruir la vista del journal sellado y reintentar la publicación. Mientras tanto, el backup puede coincidir con el principal, que sigue siendo la base de la generación pendiente. |
| Después de publicar y antes de retirar el journal | Reconocer la generación ya publicada, retirar el journal y comenzar otro recorrido. |
| Principal ausente o corrupto con backup válido | Restaurar el backup mediante un temporal. Reproducir el journal si corresponde a esa base. Si pertenecía a una generación posterior perdida, empezar otro recorrido desde el backup. |
| Principal y backup inválidos | Detenerse y conservar las copias para diagnóstico. |

El protocolo usa Flush(true) para los contenidos y renombres en el mismo volumen para publicar copias completas. La durabilidad del renombre ante una pérdida de energía depende del volumen y del almacenamiento. Las pruebas de proceso cubren la interrupción del scanner. La prueba con pérdida de energía en NTFS se realiza por separado.

### Coste de una pasada

La enumeración es secuencial y aplica la pausa de performance.json. La memoria crece con el índice, las rutas observadas, la pila de directorios y el lote del directorio actual. El journal conserva observaciones suficientes para decidir eliminaciones tras un reinicio. Un nuevo segmento vuelve a leer el índice y el journal. Cada consolidación valida y reescribe el índice completo y rota el backup. El límite de tiempo controla el recorrido entre checkpoints y deja fuera la carga y la consolidación. Estos costes se miden con archivos sintéticos antes de probar perfiles completos.

## Piloto M3 de auditoría local

El piloto abre en solo lectura archivos TXT y CSV elegibles. Antes de leer, comprueba que los metadatos del archivo abierto coincidan con los obtenidos durante el descubrimiento. La lectura se limita por tamaño y el motor de expresiones regulares limita el tiempo de búsqueda y el recuento por regla. CSV se interpreta como texto completo. Los extractores de Office y PDF quedan para una ampliación del piloto.

El checkpoint conserva `lastLocalAuditUtc` y `localAuditRulesHash` para auditorías completadas. El índice conserva la marca de finalización y la huella de las reglas, mientras que el log de la invocación guarda los recuentos. Las marcas se invalidan al cambiar los metadatos, las reglas o el extractor, al vencer el intervalo de reescaneo o al forzar una pasada. Un error de auditoría se registra aparte de los errores de descubrimiento y queda pendiente de reintento. La escritura y recuperación del estado siguen el protocolo de M2.1.

`Test-ContentAudit.ps1` comprueba positivos y negativos sintéticos para TXT y CSV, el recuento, el manejo de archivos omitidos y UTF-8 inválido, la reanudación, la reutilización, los cambios de archivo y regla y la integridad de los documentos. La cobertura de esta regla sintética se limita al corpus de prueba.

### Prueba pendiente en un tenant de laboratorio

1. Con una identidad de prueba y una directiva publicada, inicializar un motor File SDK, cargar tipos de información confidencial y registrar qué reglas están disponibles para esa identidad. [Inicialización del SDK](https://learn.microsoft.com/en-us/information-protection/develop/quick-app-initialization-csharp), [motor File SDK](https://learn.microsoft.com/en-us/dotnet/api/microsoft.informationprotection.file.ifileengine?view=mipsdk-dotnet-1.18)
2. Usar un corpus sintético con positivos y negativos por formato. Ejecutar `ClassifyAsync`, observar las solicitudes de `FileExecutionState.GetClassificationResults` y registrar qué resultados debe aportar el detector local y qué acciones devuelve la directiva. Verificar hash y fecha de escritura antes y después de la prueba. [IFileHandler](https://learn.microsoft.com/en-us/dotnet/api/microsoft.informationprotection.file.ifilehandler?view=mipsdk-dotnet-1.18), [FileExecutionState](https://learn.microsoft.com/en-us/dotnet/api/microsoft.informationprotection.file.fileexecutionstate?view=mipsdk-dotnet-1.18)
3. Para comparar la cobertura con `Set-FileLabel -AutoLabel`, usar copias desechables del corpus. Registrar la etiqueta inicial, la etiqueta resultante y los formatos admitidos. Esta comparación se realiza fuera del modo auditoría porque el cmdlet puede escribir etiquetas. [Set-FileLabel](https://learn.microsoft.com/en-us/powershell/module/purviewinformationprotection/set-filelabel?view=azureipps)
