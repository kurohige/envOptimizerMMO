# envOptimizerMMO — Guía de uso (Español)

> Otros idiomas: [English](INSTRUCTIONS.en.md) · [Documentación de referencia →](README.md)

Esta guía te lleva paso a paso por el uso del conjunto de herramientas. Es la versión amigable del `README.md`, que es la referencia técnica completa.

---

## Qué hace este toolkit, en palabras simples

- **`Set-GameAffinity.ps1`** — le indica a Windows que ejecute el juego usando un conjunto específico de núcleos del procesador. Para BDO en un Intel 13900K esto significa los 6 P-cores rápidos (sin hyperthreading y evitando el núcleo 0), lo que reduce el stutter y mejora los FPS en los momentos más exigentes. En procesadores AMD X3D (7950X3D, 9950X3D) fija el juego al chiplet que tiene la caché L3 adicional, donde BDO rinde mejor.
- **`GamingMode.ps1`** — herramienta previa a la sesión: sube el plan de energía a High Performance, libera memoria de aplicaciones en segundo plano, vacía la caché DNS y hace una prueba rápida de ping para que sepas si tu conexión está bien. Todo lo que modifica se revierte cuando lo ejecutas después con `-Stop`.
- **`NetworkOptimize.ps1`** — optimizaciones de red que se aplican una sola vez, enfocadas en reducir desconexiones aleatorias y latencia de paquetes pequeños. Los valores por defecto son seguros; las modificaciones más agresivas se activan con banderas específicas.
- **`Undo-NetworkChanges.ps1`** — revierte exactamente lo que `NetworkOptimize.ps1` aplicó.
- **`WinMaintenance.ps1`** — mantenimiento semanal: limpia archivos temporales con más de 3 días, caché de Windows Update, optimiza las unidades (TRIM en SSD, desfragmentación en HDD) y ejecuta el verificador de archivos del sistema una vez al mes. Nada de esto es destructivo; también puedes correrlo con `-DryRun` para ver qué limpiaría sin tocar nada.
- **`Setup-Scheduler.ps1`** — registra el script de mantenimiento para que se ejecute automáticamente cada semana.

Los dos archivos auxiliares `_CpuTopology.ps1` y `_GameProfile.ps1` son de uso interno. No los ejecutas directamente.

---

## Antes de la primera ejecución

### Requisitos

- Windows 10 (build 1607 o posterior) o Windows 11.
- PowerShell 5.1 — viene incluido con Windows, no hay que instalar nada.
- Acceso de administrador en el equipo (no todos los scripts lo requieren, pero la mayoría sí).

### Cómo descargar el repositorio

1. En GitHub, haz clic en el botón verde **Code** → **Download ZIP**.
2. Descomprime la carpeta donde quieras. Una ubicación común es `D:\envOptimizerMMO\` o `C:\envOptimizerMMO\`.
3. Recuerda la ruta completa. La vas a necesitar.

### Permitir que se ejecuten scripts de PowerShell

Windows bloquea los scripts de PowerShell por defecto. Los lanzadores `.bat` incluidos (`Run-*.bat`) evitan este problema automáticamente usando `-ExecutionPolicy Bypass`. Si quieres ejecutar los archivos `.ps1` directamente desde PowerShell, puedes seguir usando los lanzadores `.bat`, o ejecutar **una sola vez por usuario**:

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

Esto permite ejecutar scripts locales pero sigue bloqueando scripts no firmados descargados de internet — un punto medio seguro.

### Abrir PowerShell como administrador

Varios scripts requieren permisos de administrador.

- Presiona la **tecla Windows** → escribe **PowerShell** → clic derecho en **Windows PowerShell** → **Ejecutar como administrador**.
- Navega a la carpeta del toolkit:

```powershell
cd "D:\envOptimizerMMO"
```

Alternativa: los lanzadores `.bat` manejan la elevación por ti. Haz clic derecho en cualquier `Run-*.bat` y selecciona **Ejecutar como administrador**.

---

## Inicio rápido (5 minutos)

El camino más corto desde cero hasta "mi juego va mejor":

```powershell
# 1. Ver cómo es tu procesador (no requiere admin — no cambia nada)
.\Set-GameAffinity.ps1 -ShowTopology

# 2. Aplicar las optimizaciones de red seguras (requiere admin). Reinicia después.
.\NetworkOptimize.ps1

# 3. Registrar el mantenimiento semanal (requiere admin). Solo una vez.
.\Setup-Scheduler.ps1
```

Ahora, cada vez que vayas a jugar:

```powershell
# Antes de abrir el juego
.\GamingMode.ps1

# Lanzar BDO con la afinidad ya aplicada (reemplaza la ruta con tu instalación)
.\Set-GameAffinity.ps1 -LaunchGame "C:\Pearl Abyss\Black Desert Online\BlackDesertLauncher.exe"

# Al terminar la sesión — revertir los cambios de GamingMode
.\GamingMode.ps1 -Stop
```

Eso es todo. Solo sigue leyendo si algo no funciona o si quieres personalizar algo.

---

## Primera configuración, paso a paso

### Paso 1: ver qué detecta la herramienta en tu procesador

```powershell
.\Set-GameAffinity.ps1 -ShowTopology
```

Vas a ver una tabla con tus núcleos físicos, cuáles son P-cores y cuáles son E-cores (si es Intel híbrido), cuántos procesadores lógicos tiene cada núcleo, y el agrupamiento de caché L3. Si tienes AMD X3D dual-CCD, deberías ver dos CCDs con tamaños distintos de L3 y uno marcado como **V-CACHE CCD**.

Al final verás la máscara de afinidad que calcularía para BDO en tu chip; por ejemplo `0x1554` en un i9-13900K. **Este paso no cambia nada** — solo te muestra qué ve la herramienta.

### Paso 2: aplicar la optimización de red una vez

```powershell
.\NetworkOptimize.ps1
```

Esto crea una copia de seguridad completa del registro en la carpeta `backups\` antes de hacer cualquier cambio, así siempre puedes revertir. Se recomienda **reiniciar después**.

Lo que se aplica por defecto:
- Desactiva la administración de energía de la NIC (causa común de desconexiones aleatorias en Wi-Fi/Ethernet).
- Desactiva Energy Efficient Ethernet en adaptadores por cable.
- Ajusta el registro de MMCSS para que los juegos tengan prioridad de CPU sobre tareas de fondo.

Lo que puedes activar manualmente:
- `-AggressiveTcp` — ajustes por-interfaz de Nagle / retraso de ACK. Ayuda en algunos juegos; no está claramente demostrado para BDO.
- `-AggressiveKeepalive` — keepalive TCP de 60 segundos a nivel sistema. Ojo: afecta a todas las conexiones de red del PC, no solo al juego.
- `-SetDNS cloudflare` o `-SetDNS google` — cambia DNS. Solo vale la pena si el DNS de tu proveedor es lento o poco confiable.

Si después de este paso algo se siente raro, ejecuta `.\Undo-NetworkChanges.ps1` y reinicia.

### Paso 3: programar el mantenimiento semanal

```powershell
.\Setup-Scheduler.ps1
```

Por defecto crea una tarea programada que ejecuta `WinMaintenance.ps1` cada domingo a las 3:00 AM. Si el PC está apagado a esa hora, se ejecuta la próxima vez que lo enciendas. Puedes cambiar el día y la hora:

```powershell
.\Setup-Scheduler.ps1 -Day Saturday -Time "04:00"
```

Para eliminar la tarea:

```powershell
.\Setup-Scheduler.ps1 -Remove
```

---

## Uso sesión a sesión

### Antes de jugar

```powershell
.\GamingMode.ps1
```

Comportamiento por defecto (seguro):
- Plan de energía → High Performance (no Ultimate — ver nota abajo).
- Libera memoria de aplicaciones en segundo plano.
- Informa si Memory Integrity / VBS está activo (consume 3–8% de CPU en juegos; la herramienta solo reporta, no lo desactiva).
- Vacía la caché DNS.
- Corre una prueba de calidad de conexión y te muestra latencia/jitter.
- Lista aplicaciones pesadas en segundo plano aún abiertas (OneDrive, Chrome, Discord, etc.) para que puedas cerrarlas si quieres.
- También ejecuta `NetworkOptimize.ps1` con valores seguros.

Banderas útiles:
- `-Ultimate` — usa el plan Ultimate Performance. **Se rechaza en laptops** (provoca thermal throttling y consume batería). En desktops: algo más agresivo que High Performance, pero la diferencia medible en juegos es menor al 1%.
- `-DisableMemoryCompression` — opcional. Reduce la carga de CPU del compresor de memoria en equipos con RAM de sobra. Se reactiva automáticamente con `-Stop`.
- `-DisablePciLinkPower` — opcional. Desactiva PCI Express ASPM. Aplícalo solo si has detectado picos de latencia atribuibles a esto. Se reactiva automáticamente con `-Stop`.
- `-GameMode enable` o `-GameMode disable` — control explícito del Game Mode de Windows. Por defecto se deja como está.
- `-SkipNetwork` — salta la optimización de red (útil si ya la corriste hoy).

### Lanzar el juego

Tienes dos opciones.

**Opción A — Modo de herencia desde el launcher (recomendada para BDO).** El script lanza el launcher de BDO con la afinidad ya aplicada, para que el juego herede la máscara antes de que EasyAntiCheat empiece a vigilar.

```powershell
.\Set-GameAffinity.ps1 -LaunchGame "C:\Pearl Abyss\Black Desert Online\BlackDesertLauncher.exe"
```

Si juegas por Steam:

```powershell
.\Set-GameAffinity.ps1 -LaunchGame "C:\Pearl Abyss\Black Desert Online\BlackDesertLauncher.exe" -Steam
```

**Opción B — Modo de adjuntado.** Inicia BDO de forma normal y luego ejecuta el script; espera a que aparezca el proceso del juego, aplica la afinidad y activa un watchdog que la reaplica si EAC la cambia.

```powershell
.\Set-GameAffinity.ps1
```

Ambos modos funcionan. La Opción A es el método estándar en la comunidad de BDO y suele ser más confiable.

### Al terminar

```powershell
.\GamingMode.ps1 -Stop
```

Esto deshace todo lo que `GamingMode.ps1` cambió: plan de energía, compresión de memoria (si la desactivaste), PCI link power, y Game Mode.

---

## Revertir cambios

- **Cambios de red**: `.\Undo-NetworkChanges.ps1`. Reinicia después.
- **Cambios de sesión (plan de energía, compresión de memoria, PCI link power, Game Mode)**: `.\GamingMode.ps1 -Stop`.
- **Mantenimiento programado**: `.\Setup-Scheduler.ps1 -Remove`.
- **Afinidad del CPU**: cuando el proceso del juego se cierra, la afinidad desaparece. Si quieres detener el watchdog mientras el juego sigue abierto, presiona **Ctrl+C** en la ventana de PowerShell.

---

## Solución de problemas

**"El script no se puede ejecutar porque contiene una sentencia `#requires` para ejecutar como administrador."**
La ventana actual de PowerShell no tiene permisos elevados. Ciérrala y abre PowerShell como administrador, o haz clic derecho en el lanzador `Run-*.bat` y selecciona **Ejecutar como administrador**.

**"La afinidad de BDO se sigue reseteando durante la sesión."**
EasyAntiCheat puede resetear la afinidad de los procesos. Dos soluciones:
1. Usa el modo `-LaunchGame` — EAC ve la máscara desde el arranque y normalmente no la toca.
2. El watchdog en modo de adjuntado detecta el cambio y vuelve a aplicar la máscara. Revisa el log; si ves muchas líneas del tipo `Affinity drifted on PID ... Reapplying.`, EAC está peleando con nosotros — cambia al modo `-LaunchGame`.

**"`Set-GameAffinity.ps1 -ShowTopology` no detecta mi X3D como V-Cache."**
La detección por tamaño de L3 necesita dos CCDs con tamaños notablemente distintos (ratio ≥2×). En 7800X3D / 9800X3D (un solo CCD) no hay asimetría para detectar — esto es esperado, y la estrategia de BDO para single-CCD X3D igual se aplica correctamente. En 7950X3D / 9950X3D, si ves un solo CCD, actualiza el driver del chipset de AMD y reinicia.

**"Corrí algo y mi PC se siente raro."**
Ejecuta el undo correspondiente. `.\Undo-NetworkChanges.ps1` para lo de red; `.\GamingMode.ps1 -Stop` para los cambios de sesión. Reinicia después de cambios de red.

**"Game Mode — ¿lo activo o lo desactivo?"**
Por defecto se deja como esté. En Windows 11 la mayoría de jugadores lo dejan activado. En Windows 10 hay reportes de que Game Mode afecta otras apps en segundo plano (en particular streams de OBS). Microsoft no publica una posición oficial sobre esta diferencia. Si estás en Windows 10 y haces stream, pasa `-GameMode disable` a GamingMode.ps1; si no, déjalo.

**"Memory Integrity / VBS — ¿lo desactivo?"**
La herramienta reporta su estado pero no lo modifica. Desactivarlo te devuelve 3–8% de CPU en juegos, pero reduce el aislamiento de drivers del kernel (la protección principal que ofrece VBS). Para un equipo dedicado a juegos, muchos usuarios lo desactivan y aceptan el compromiso. Se cambia en **Configuración → Seguridad de Windows → Seguridad del dispositivo → Aislamiento del núcleo**. Requiere reiniciar desde la BIOS.

---

## Dónde encontrar más información

- `README.md` es la referencia completa: cada ajuste con su fuente, por qué se aplica o se omite, y secciones sobre configuración del driver de GPU, opciones in-game de BDO, servicios que desactivar y recomendaciones de hardware que deliberadamente no se automatizan.
- La receta específica de afinidad de CPU para BDO está basada en [la guía de ACanadianDude](https://docs.google.com/document/d/1cyLaDiPL_B6nOZw_qPE_wOGuoeRT-qddTjevTFoFBkg/edit). Léela si quieres el razonamiento detrás de "6 P-cores / sin HT / omitir core 0".

Si algo no funciona o piensas que una recomendación está equivocada, abre un issue en el repositorio.
