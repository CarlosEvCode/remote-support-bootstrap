# Remote Support Bootstrap

Plan B para soporte de equipos Windows cuando RustDesk o AnyDesk no funcionan.
VNC no se publica: TightVNC queda detrás de SSH.

```text
Linux ── ZeroTier o Cloudflare Tunnel ── SSH ── 127.0.0.1:5900 (TightVNC)
```

## Instalación rápida y sin descargas repetidas

El instalador detecta OpenSSH, ZeroTier, cloudflared y TightVNC ya instalados,
por lo que no los reinstala. Las MSI verificadas quedan en una caché persistente:

```text
C:\ProgramData\RemoteSupportBootstrap\installers
```

En una nueva ejecución se usa esa caché. Primero intenta obtener cada asset del
último Release de este repositorio y, si aún no está publicado, usa el proveedor
oficial. Siempre exige una firma Authenticode válida antes de instalar.

Para preparar otro equipo sin Internet, copia la caché a una USB y ejecuta:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-RemoteSupport.ps1 -InstallerSource 'E:\installers'
```

Usa `-RefreshInstallers` solo si quieres reemplazar deliberadamente la caché.

### Assets en GitHub Releases

No subas binarios a Git: harían pesados los clones y el historial. Para este
proyecto sí es apropiado adjuntarlos a un Release publicado. Sube las MSI desde
sus proveedores oficiales, revisa que tengan firma digital válida en Windows y
usa exactamente estos nombres (el instalador usa `releases/latest/download`):

- `ZeroTier-One.msi`
- `cloudflared-windows-amd64.msi`
- `tightvnc-4.0.2-x64.msi`

## Uso en Windows

Abre PowerShell como administrador y descarga una copia revisable. Este es el
método recomendado: conserva el contexto de un archivo `.ps1` y evita
`Invoke-Expression`.

```powershell
$url = 'https://raw.githubusercontent.com/CarlosEvCode/remote-support-bootstrap/main/Install-RemoteSupport.ps1'
$file = Join-Path ([IO.Path]::GetTempPath()) 'Install-RemoteSupport.ps1'
Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $file
notepad $file
powershell -NoProfile -ExecutionPolicy Bypass -File $file
```

Si prefieres una sola línea, úsala igualmente sin `iex`:

```powershell
$f = Join-Path ([IO.Path]::GetTempPath()) 'Install-RemoteSupport.ps1'; iwr -UseBasicParsing 'https://raw.githubusercontent.com/CarlosEvCode/remote-support-bootstrap/main/Install-RemoteSupport.ps1' -OutFile $f; powershell -NoProfile -ExecutionPolicy Bypass -File $f
```

El Network ID predeterminado es `c1644bfd5484e1f8`. Autoriza el equipo nuevo en
ZeroTier Central. Durante el instalador interactivo de TightVNC, configura una
contraseña fuerte; nunca viaja ni queda escrita en este repositorio.

## Conexión primaria desde Linux

Busca la IP administrada del equipo en ZeroTier Central:

```bash
ssh -N -L 5901:127.0.0.1:5900 USUARIO_WINDOWS@IP_ZEROTIER
vncviewer localhost:5901
```

## Respaldo Cloudflare

En Windows:

```powershell
powershell -ExecutionPolicy Bypass -File 'C:\ProgramData\RemoteSupportBootstrap\Start-CloudflareSupport.ps1'
```

Comparte el host `*.trycloudflare.com`. En Linux:

```bash
ssh -N -L 5901:127.0.0.1:5900 \
  -o 'ProxyCommand=cloudflared access ssh --hostname %h' \
  USUARIO_WINDOWS@HOST.trycloudflare.com
vncviewer localhost:5901
```

## Deshacer únicamente los cambios del bootstrap

El instalador guarda qué componentes ya existían y cuáles instaló él. Para
retirar solo sus cambios, abre PowerShell como administrador y ejecuta:

```powershell
powershell -ExecutionPolicy Bypass -File 'C:\ProgramData\RemoteSupportBootstrap\Uninstall-RemoteSupport.ps1'
```

Pedirá confirmación. Elimina únicamente su regla de firewall, abandona ZeroTier
solo si el bootstrap unió la red, y desinstala solo componentes que este
bootstrap haya instalado. Si falta el registro de estado, se detiene sin tocar
software ajeno.

## Notas de seguridad

- SSH entrante queda permitido solo por el adaptador ZeroTier.
- No se crea una regla para VNC ni se abren TCP/5900 en LAN o Internet.
- No incluye contraseñas, claves SSH ni tokens.
- Cloudflare es temporal: el túnel muere al cerrar esa ventana y su dominio cambia.
