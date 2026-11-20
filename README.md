# Remote Support Bootstrap

Tres rutas de respaldo para Windows. **RustDesk sigue siendo la primera opción.**

## Rutas disponibles

| Ruta | Cómo llega el técnico | Cuándo usarla |
| --- | --- | --- |
| **Cloudflare TCP + TightVNC** (Opción 1) | Quick Tunnel temporal TCP directo a VNC (`tcp://localhost:5900`) | **Principal y recomendada:** No requiere abrir puertos, ni VPN, ni contraseñas de Windows (ideal para cuentas sin clave, PIN o Hello) |
| **ZeroTier + TightVNC** (Opción 2) | IP administrada de ZeroTier, puerto `5900` | Segunda opción si ambos equipos tienen o pueden instalar ZeroTier |
| **Cloudflare + SSH + TightVNC** (Opción 3) | Quick Tunnel temporal que publica SSH; reenvío SSH a VNC | Respaldo adicional cuando se requiere explícitamente túnel SSH (requiere contraseña de Windows) |

Todas las rutas instalan **TightVNC** y usan **winget** como fuente principal. Si winget o la descarga del proveedor están bloqueados (por ejemplo por Fortinet), el script descarga el MSI exacto desde el Release [`bootstrap-assets-v2`](https://github.com/CarlosEvCode/remote-support-bootstrap/releases/tag/bootstrap-assets-v2) y valida su **SHA-256** antes de instalar.

Versiones fijadas:

- TightVNC `2.8.89`
- ZeroTier One `1.16.2`
- cloudflared `2026.11.1`

## Ejecutar en Windows

Abre **PowerShell como administrador**:

```powershell
$url = 'https://raw.githubusercontent.com/CarlosEvCode/remote-support-bootstrap/main/Install-RemoteSupport.ps1'
$file = Join-Path ([IO.Path]::GetTempPath()) 'Install-RemoteSupport.ps1'
Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $file
powershell -NoProfile -ExecutionPolicy Bypass -File $file
```

El script muestra un menú para elegir la ruta (por defecto la opción 1). También puedes especificarla directamente:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-RemoteSupport.ps1 -Flow CloudflareVnc
powershell -ExecutionPolicy Bypass -File .\Install-RemoteSupport.ps1 -Flow ZeroTier
powershell -ExecutionPolicy Bypass -File .\Install-RemoteSupport.ps1 -Flow Cloudflare
```

Si winget está bloqueado pero GitHub no, fuerza los MSI del Release:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-RemoteSupport.ps1 -Flow ZeroTier -ForceRelease
```

El script deja **TightVNC Server** registrado como servicio, iniciado en `TCP/5900` y con una contraseña VNC configurada. Por defecto usa `1224` (VNC admite máximo 8 caracteres). Puedes cambiarla o desactivar la autenticación:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-RemoteSupport.ps1 -Flow ZeroTier -VncPassword 'MiClave1'
powershell -ExecutionPolicy Bypass -File .\Install-RemoteSupport.ps1 -Flow ZeroTier -DisableVncAuth
```

`-DisableVncAuth` deja el escritorio sin contraseña; úsalo solo en una VM de prueba.

En la ruta Cloudflare el script también activa `AllowLoopback`, necesario para que el reenvío SSH llegue a `127.0.0.1:5900`.

## Conectar por ZeroTier

1. El script une el equipo a la red `c1644bfd5484e1f8` y muestra su **Node ID**.
2. Autoriza ese nodo en [ZeroTier Central](https://my.zerotier.com/).
3. Desde el otro equipo, conecta el visor VNC a la Managed IP del nodo:

```text
IP_ZEROTIER:5900
```

## Conectar por Cloudflare

La ruta Cloudflare instala OpenSSH Server, lo deja iniciado, crea un lanzador y **abre el túnel automáticamente en una ventana nueva** al terminar. El dominio `*.trycloudflare.com` aparece en esa ventana y también en la salida del instalador; el túnel queda corriendo hasta cerrar la ventana o pulsar `Ctrl+C`.

Si no quieres que se abra automáticamente:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-RemoteSupport.ps1 -Flow Cloudflare -NoAutoStart
```

En ese caso puedes iniciarlo después con:

```powershell
powershell -ExecutionPolicy Bypass -File 'C:\ProgramData\RemoteSupportBootstrap\Start-CloudflareSupport.ps1'
```

Comparte **solo** el host `*.trycloudflare.com`. El túnel publica únicamente SSH; VNC nunca se expone directamente.

> **Importante:** SSH usa la contraseña de la cuenta de Windows. Por defecto, Windows bloquea el inicio de sesión remoto de cuentas locales **sin contraseña** (`LimitBlankPasswordUse=1`). En ese caso usa la ruta ZeroTier o asigna una contraseña a la cuenta / crea una cuenta de soporte con contraseña. El PIN o Windows Hello no sirven para SSH.

Desde Linux:

```bash
ssh -N -L 5901:127.0.0.1:5900 \
  -o 'ProxyCommand=cloudflared access ssh --hostname %h' \
  USUARIO_WINDOWS@HOST.trycloudflare.com
vncviewer localhost:5901
```

El lanzador usa `--protocol http2` por defecto para redes restrictivas. Si tu red permite QUIC, puedes ejecutarlo con `-Protocol quic`. El túnel se cierra al cerrar su ventana o presionar `Ctrl+C`.

## Conectar por Cloudflare TCP (Flujo 3: Sin contraseña de Windows)

Este flujo expone directamente TightVNC a través del túnel temporal de Cloudflare (`tcp://localhost:5900`), **sin requerir OpenSSH Server ni usuario/contraseña de Windows**.

1. Ejecuta en Windows:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\Install-RemoteSupport.ps1 -Flow CloudflareVnc
   ```
2. El túnel se abre en una ventana independiente y genera el dominio `*.trycloudflare.com`.
3. Desde Linux, el técnico crea el proxy TCP local:
   ```bash
   cloudflared access tcp --hostname HOST.trycloudflare.com --url 127.0.0.1:5901
   ```
4. En otra terminal, abre el visor VNC apuntando al listener local:
   ```bash
   vncviewer localhost:5901
   ```
   (Usa la contraseña de VNC configurada, por defecto `1224`).

## Assets de respaldo

El Release `bootstrap-assets-v2` contiene exactamente los instaladores de las versiones fijadas:

- `tightvnc-2.8.89-x64.msi`
- `ZeroTier-One-1.16.2.msi`
- `cloudflared-2026.11.1-windows-amd64.msi`

Los SHA-256 están fijados en `Install-RemoteSupport.ps1` y coinciden con los manifiestos oficiales de [winget-pkgs](https://github.com/microsoft/winget-pkgs).
