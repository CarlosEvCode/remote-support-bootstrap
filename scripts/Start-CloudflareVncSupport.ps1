[CmdletBinding()]
param(
    [ValidateSet('auto', 'http2', 'quic')]
    [string] $Protocol = 'http2',

    [ValidateRange(1, 65535)]
    [int] $LocalPort = 5900,

    [string] $UrlFile
)

$ErrorActionPreference = 'Stop'

if (-not $UrlFile) {
    $commonAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    $UrlFile = Join-Path (Join-Path $commonAppData 'RemoteSupportBootstrap') 'cloudflare-vnc-url.txt'
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
    if (-not $found) { throw 'cloudflared no esta instalado. Ejecuta primero Install-RemoteSupport.ps1 -Flow CloudflareVnc.' }
    return $found
}

$cloudflared = Find-Cloudflared

$vnc = Get-NetTCPConnection -LocalPort $LocalPort -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $vnc) {
    Write-Warning "No se detecta servicio escuchando en TCP/$LocalPort. Revisa TightVNC Server."
}

$urlDirectory = Split-Path -Parent $UrlFile
if ($urlDirectory) { New-Item -ItemType Directory -Force -Path $urlDirectory | Out-Null }
Remove-Item -LiteralPath $UrlFile -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host '===========================================================' -ForegroundColor Cyan
Write-Host '  Abriendo tunel temporal Cloudflare TCP directo para VNC   ' -ForegroundColor Cyan
Write-Host '  (Flujo 3: Sin contrasena de Windows / Sin SSH requerido)  ' -ForegroundColor Cyan
Write-Host '===========================================================' -ForegroundColor Cyan
Write-Host "Puerto local reenviado: TCP/$LocalPort" -ForegroundColor DarkGray
Write-Host 'Comparte SOLO el host *.trycloudflare.com que aparezca abajo con el tecnico.' -ForegroundColor Yellow
Write-Host 'El tunel termina al cerrar esta ventana o presionar Ctrl+C.' -ForegroundColor Yellow
Write-Host ''
Write-Host 'En Linux, el tecnico ejecuta:' -ForegroundColor Cyan
Write-Host '  1) Iniciar proxy local:'
Write-Host '     cloudflared access tcp --hostname HOST.trycloudflare.com --url 127.0.0.1:5901'
Write-Host '  2) En otra terminal abrir el visor VNC:'
Write-Host '     vncviewer localhost:5901'
Write-Host ''

$previous = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & $cloudflared tunnel --url "tcp://localhost:$LocalPort" --protocol $Protocol 2>&1 | ForEach-Object {
        $line = $_.ToString()
        Write-Host $line
        if ($line -match '(https://[A-Za-z0-9.-]+\.trycloudflare\.com)') {
            $url = $Matches[1]
            Set-Content -LiteralPath $UrlFile -Value $url -Encoding ASCII
            $hostOnly = $url -replace '^https?://', ''
            Write-Host ''
            Write-Host "===========================================================" -ForegroundColor Green
            Write-Host "DOMINIO CLOUDFLARE: $url" -ForegroundColor Green
            Write-Host "HOST PARA EL TECNICO: $hostOnly" -ForegroundColor Green
            Write-Host "===========================================================" -ForegroundColor Green
            Write-Host ''
            Write-Host 'Comando Linux para el tecnico:' -ForegroundColor Yellow
            Write-Host "cloudflared access tcp --hostname $hostOnly --url 127.0.0.1:5901" -ForegroundColor Yellow
            Write-Host ''
        }
    }
    $exitCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $previous
}

if ($exitCode -ne 0) {
    Write-Warning "cloudflared termino con codigo $exitCode."
}
