[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Find-Cloudflared {
    $command = Get-Command cloudflared.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }

    $candidates = @(
        "$env:ProgramFiles\cloudflared\cloudflared.exe",
        "${env:ProgramFiles(x86)}\cloudflared\cloudflared.exe",
        'C:\Cloudflared\bin\cloudflared.exe'
    )
    $found = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $found) {
        throw 'cloudflared no esta instalado. Ejecuta primero Install-RemoteSupport.ps1.'
    }
    return $found
}

$cloudflared = Find-Cloudflared
Write-Host ''
Write-Host 'Abriendo tunel temporal de Cloudflare para SSH...' -ForegroundColor Cyan
Write-Host 'Comparte SOLO el host *.trycloudflare.com que aparezca abajo con el tecnico.' -ForegroundColor Yellow
Write-Host 'El tunel termina al cerrar esta ventana o presionar Ctrl+C.' -ForegroundColor Yellow
Write-Host ''
Write-Host 'En Linux, el tecnico ejecuta:' -ForegroundColor Cyan
Write-Host "ssh -N -L 5901:127.0.0.1:5900 -o 'ProxyCommand=cloudflared access ssh --hostname %h' USUARIO_WINDOWS@HOST.trycloudflare.com"
Write-Host 'y despues: vncviewer localhost:5901'
Write-Host ''

& $cloudflared tunnel --url ssh://localhost:22
