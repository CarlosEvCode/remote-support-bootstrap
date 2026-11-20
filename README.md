# Remote Support Bootstrap

Plan B para soporte de equipos Windows cuando RustDesk o AnyDesk no funcionen en la red del cliente.

El diseño evita publicar VNC. TightVNC queda detrás de SSH y se alcanza desde Linux mediante un reenvío local:

```text
Linux ── ZeroTier o Cloudflare Tunnel ── SSH ── 127.0.0.1:5900 (TightVNC)
```

## Uso en Windows

Abre **PowerShell como administrador** y ejecuta primero la forma revisable:

```powershell
$repo = 'https://raw.githubusercontent.com/CarlosEvCode/remote-support-bootstrap/main'
Invoke-WebRequest "$repo/Install-RemoteSupport.ps1" -OutFile "$env:TEMP\Install-RemoteSupport.ps1"
notepad "$env:TEMP\Install-RemoteSupport.ps1"
powershell -ExecutionPolicy Bypass -File "$env:TEMP\Install-RemoteSupport.ps1"
```

El atajo de una sola línea también funciona, pero ejecútalo solo si confías en la versión pública del repositorio:

```powershell
irm https://raw.githubusercontent.com/CarlosEvCode/remote-support-bootstrap/main/Install-RemoteSupport.ps1 | iex
```

El Network ID predeterminado es `c1644bfd5484e1f8`. Al terminar, el propietario debe autorizar el nuevo equipo en ZeroTier Central.

Durante la instalación de TightVNC, configura una contraseña fuerte. El instalador se abre de forma interactiva deliberadamente: una contraseña no debe viajar en el comando, historial de PowerShell ni repositorio.

## Conexión primaria desde Linux

Busca la IP administrada del equipo en ZeroTier Central y reemplaza los valores:

```bash
ssh -N -L 5901:127.0.0.1:5900 USUARIO_WINDOWS@IP_ZEROTIER
vncviewer localhost:5901
```

La primera orden queda abierta mientras dure la sesión VNC.

## Respaldo Cloudflare

En Windows, cuando se necesite soporte puntual:

```powershell
powershell -ExecutionPolicy Bypass -File 'C:\ProgramData\RemoteSupportBootstrap\Start-CloudflareSupport.ps1'
```

Comparte el host `*.trycloudflare.com` que muestre. En Linux:

```bash
ssh -N -L 5901:127.0.0.1:5900 \
  -o 'ProxyCommand=cloudflared access ssh --hostname %h' \
  USUARIO_WINDOWS@HOST.trycloudflare.com
vncviewer localhost:5901
```

El túnel Cloudflare es temporal: muere al cerrar esa ventana y su dominio cambia cada vez.

## Notas de seguridad

- El instalador deja SSH entrante solo por el adaptador ZeroTier; no abre SSH en la LAN o Internet.
- No crea una regla de firewall para VNC. VNC debe usarse solo a través del túnel SSH local.
- No incluye contraseñas, claves SSH ni tokens en el repositorio.
- El fallback de Cloudflare no ayuda si la red también bloquea las salidas que necesita `cloudflared`.
