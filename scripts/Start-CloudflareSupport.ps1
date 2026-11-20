[CmdletBinding()]
param(
    [ValidateSet('auto', 'http2', 'quic')]
    [string] $Protocol = 'http2'
)

$ErrorActionPreference = 'Stop'

function Assert-LocalSshReady {
    $service = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if (-not $service) { throw 'OpenSSH Server no esta instalado. Ejecuta primero Install-RemoteSupport.ps1 -Flow Cloudflare.' }
    if ($service.Status -ne 'Running') { throw 'El servicio sshd no esta ejecutandose. Abre PowerShell como administrador y ejecuta Start-Service sshd.' }
    $listener = Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue
    if (-not $listener) { throw 'sshd esta activo pero no escucha en TCP/22; revisa su configuracion antes de abrir el tunel.' }
}

function Find-Cloudflared {
    $command = Get-Command cloudflared.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }

    $candidates = @(
        "$env:ProgramFiles\cloudflared\cloudflared.exe",
        "${env:ProgramFiles(x86)}\cloudflared\cloudflared.exe",
        'C:\Cloudflared\bin\cloudflared.exe'
    )
    $found = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $found) { throw 'cloudflared no esta instalado. Ejecuta primero Install-RemoteSupport.ps1 -Flow Cloudflare.' }
    return $found
}

$cloudflared = Find-Cloudflared
Assert-LocalSshReady

$vnc = Get-NetTCPConnection -LocalPort 5900 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $vnc) {
    Write-Warning 'No se detecta TightVNC escuchando en TCP/5900. Revisa el Control Center (System Service) y su contrasena.'
}

Write-Host ''
Write-Host 'Abriendo tunel temporal de Cloudflare para SSH...' -ForegroundColor Cyan
Write-Host "Usuario SSH de esta sesion: $env:USERNAME" -ForegroundColor Cyan
Write-Host 'Comparte SOLO el host *.trycloudflare.com que aparezca abajo con el tecnico.' -ForegroundColor Yellow
Write-Host 'El tunel termina al cerrar esta ventana o presionar Ctrl+C.' -ForegroundColor Yellow
Write-Host ''
Write-Host 'En Linux, el tecnico ejecuta:' -ForegroundColor Cyan
Write-Host "ssh -N -L 5901:127.0.0.1:5900 -o 'ProxyCommand=cloudflared access ssh --hostname %h' $env:USERNAME@HOST.trycloudflare.com"
Write-Host 'y despues: vncviewer localhost:5901'
Write-Host ''

& $cloudflared tunnel --url ssh://localhost:22 --protocol $Protocol
