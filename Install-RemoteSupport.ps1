#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Prepara soporte remoto en Windows con una de dos rutas:

  1) ZeroTier + TightVNC directo (recomendado).
  2) Cloudflare Quick Tunnel + SSH + TightVNC local (respaldo).

.DESCRIPTION
winget es la fuente normal. Si winget o la descarga del proveedor estan
bloqueados (por ejemplo por Fortinet), se usa el MSI exacto publicado en el
Release del repositorio y se valida su SHA-256 antes de instalar.

.PARAMETER Flow
Omite el menu: ZeroTier o Cloudflare.

.PARAMETER NetworkId
Red de ZeroTier a la que se une el equipo.

.PARAMETER ForceRelease
No intenta winget y usa directamente los MSI del Release.
#>
[CmdletBinding()]
param(
    [ValidateSet('ZeroTier', 'Cloudflare')]
    [string] $Flow,

    [ValidatePattern('^[a-fA-F0-9]{16}$')]
    [string] $NetworkId = 'c1644bfd5484e1f8',

    [switch] $ForceRelease
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$CommonAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
$InstallRoot = Join-Path $CommonAppData 'RemoteSupportBootstrap'
$ReleaseBaseUrl = 'https://github.com/CarlosEvCode/remote-support-bootstrap/releases/download/bootstrap-assets-v2'

# Versiones y hashes tomados de los manifiestos oficiales de winget-pkgs.
$Packages = [ordered]@{
    'GlavSoft.TightVNC' = @{
        Version = '2.8.89'
        Asset   = 'tightvnc-2.8.89-x64.msi'
        Sha256  = 'DFF8D7E40A81E0B86BA1D9D5CC0D4F22D08354C50C9CBDC0825BBB6CCFB1073C'
    }
    'ZeroTier.ZeroTierOne' = @{
        Version = '1.16.2'
        Asset   = 'ZeroTier-One-1.16.2.msi'
        Sha256  = '42514072B0FE44B8F66E0395BCD23A0B1D1642C28ED00831F1527B2F41B14670'
    }
    'Cloudflare.cloudflared' = @{
        Version = '2026.11.1'
        Asset   = 'cloudflared-2026.11.1-windows-amd64.msi'
        Sha256  = 'A92404494335FF48FEAADD7EF89A7144465D9BD8E3C5316F0DF722FE86B7D93E'
    }
}

function Write-Step([string] $Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Test-WingetPackage([string] $Id) {
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) { return $false }

    # winget escribe avisos en stderr; con ErrorActionPreference=Stop eso puede
    # convertirse en un error terminante aunque la consulta haya funcionado.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & winget.exe list --id $Id --exact --accept-source-agreements --disable-interactivity 2>$null | Out-String
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    return ($exitCode -eq 0 -and $output -match [regex]::Escape($Id))
}

function Get-ReleaseInstaller([string] $Id) {
    $package = $Packages[$Id]
    $cache = Join-Path $InstallRoot 'installers'
    $path = Join-Path $cache $package.Asset
    New-Item -ItemType Directory -Force -Path $cache | Out-Null

    if (Test-Path -LiteralPath $path) {
        $cachedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash
        if ($cachedHash -eq $package.Sha256) { return $path }
        Write-Warning "El MSI en cache no coincide con su SHA-256; se descargara de nuevo."
        Remove-Item -LiteralPath $path -Force
    }

    Write-Host "Descargando respaldo desde GitHub Release: $($package.Asset)" -ForegroundColor Yellow
    try {
        Invoke-WebRequest -UseBasicParsing -Uri "$ReleaseBaseUrl/$($package.Asset)" -OutFile $path
    } catch {
        throw "No se pudo descargar $($package.Asset) desde GitHub. Revisa la red o descarga el asset manualmente desde $ReleaseBaseUrl."
    }

    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash
    if ($actualHash -ne $package.Sha256) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        throw "El SHA-256 de $($package.Asset) no coincide; se cancela la instalacion."
    }
    return $path
}

function Install-FromRelease([string] $Id) {
    $path = Get-ReleaseInstaller $Id
    Write-Step "Instalando $Id desde el Release"
    $process = Start-Process msiexec.exe -ArgumentList @('/i', "`"$path`"", '/qn', '/norestart') -Wait -PassThru
    if ($process.ExitCode -notin 0, 3010) {
        throw "La instalacion de respaldo de $Id fallo con codigo $($process.ExitCode)."
    }
}

function Install-Package([string] $Id) {
    if (Test-WingetPackage $Id) {
        Write-Host "$Id ya esta instalado." -ForegroundColor DarkGray
        return
    }

    if (-not $ForceRelease -and (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        $package = $Packages[$Id]
        Write-Host "Instalando $Id $($package.Version) con winget..." -ForegroundColor DarkGray
        & winget.exe install --id $Id --exact --version $package.Version --scope machine `
            --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
        if ($LASTEXITCODE -eq 0 -and (Test-WingetPackage $Id)) { return }
        Write-Warning "winget no pudo instalar $Id; se usara el Release de respaldo."
    } elseif ($ForceRelease) {
        Write-Host "-ForceRelease activo: se omite winget para $Id." -ForegroundColor DarkGray
    } else {
        Write-Warning 'winget no esta disponible; se usara el Release de respaldo.'
    }

    Install-FromRelease $Id
    if (-not (Test-WingetPackage $Id)) {
        Write-Warning "$Id se instalo desde el Release, pero winget no lo detecta todavia. Continua si la aplicacion aparece en el sistema."
    }
}

function Get-ZeroTierCommand {
    $candidates = @(
        (Join-Path $CommonAppData 'ZeroTier\One\zerotier-one_x64.exe'),
        (Join-Path $CommonAppData 'ZeroTier\One\zerotier-one_x86.exe'),
        (Join-Path $CommonAppData 'ZeroTier\One\zerotier-cli.bat')
    )
    $command = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $command) {
        throw 'ZeroTier se instalo, pero no se encontro su comando. Reinicia el equipo y vuelve a ejecutar este script.'
    }
    return $command
}

function Invoke-ZeroTier([string] $Command, [string[]] $Arguments) {
    if ((Split-Path -Leaf $Command) -match '^zerotier-one_') {
        & $Command -q @Arguments
    } else {
        & $Command @Arguments
    }
}

function Wait-ZeroTierService {
    for ($attempt = 1; $attempt -le 15; $attempt++) {
        $service = Get-Service -Name ZeroTierOneService -ErrorAction SilentlyContinue
        if ($service -and $service.Status -eq 'Running') { return }
        Start-Sleep -Seconds 1
    }
    throw 'El servicio de ZeroTier no esta en ejecucion. Revisa services.msc y vuelve a intentarlo.'
}

function Enable-OpenSshServer {
    $capability = Get-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'
    if ($capability.State -ne 'Installed') {
        Write-Host 'Agregando la capacidad OpenSSH.Server...' -ForegroundColor DarkGray
        Add-WindowsCapability -Online -Name $capability.Name | Out-Null
    }
    if (-not (Get-Service -Name sshd -ErrorAction SilentlyContinue)) {
        throw 'OpenSSH Server no quedo instalado. Instala la capacidad OpenSSH.Server y vuelve a ejecutar este script.'
    }
    Set-Service -Name sshd -StartupType Automatic
    if ((Get-Service -Name sshd).Status -ne 'Running') {
        Start-Service -Name sshd
    }
}

function Copy-CloudflareStarter {
    New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
    $target = Join-Path $InstallRoot 'Start-CloudflareSupport.ps1'
    $localCopy = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'scripts\Start-CloudflareSupport.ps1' } else { $null }

    if ($localCopy -and (Test-Path -LiteralPath $localCopy)) {
        Copy-Item -LiteralPath $localCopy -Destination $target -Force
    } else {
        Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/CarlosEvCode/remote-support-bootstrap/main/scripts/Start-CloudflareSupport.ps1' -OutFile $target
    }
    return $target
}

if (-not $Flow) {
    Write-Host 'Elige una ruta de soporte:' -ForegroundColor Cyan
    Write-Host '  1. ZeroTier + TightVNC directo (recomendado)'
    Write-Host '  2. Cloudflare + SSH + TightVNC (respaldo temporal)'
    do {
        $choice = Read-Host 'Escribe 1 o 2'
    } until ($choice -in '1', '2')
    $Flow = if ($choice -eq '1') { 'ZeroTier' } else { 'Cloudflare' }
}

Write-Step 'Instalando TightVNC (comun a ambas rutas)'
Install-Package 'GlavSoft.TightVNC'

if ($Flow -eq 'ZeroTier') {
    Write-Step 'Instalando ZeroTier'
    Install-Package 'ZeroTier.ZeroTierOne'
    Wait-ZeroTierService

    $zeroTier = Get-ZeroTierCommand

    # En PS 5.1, redirigir stderr de un comando nativo con EAP=Stop puede
    # lanzar NativeCommandError. ZeroTier usa stderr para avisos normales.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $networks = Invoke-ZeroTier $zeroTier @('listnetworks') 2>&1 | Out-String
        if ($networks -notmatch [regex]::Escape($NetworkId)) {
            Write-Host "Uniendo el equipo a la red ZeroTier $NetworkId..." -ForegroundColor DarkGray
            Invoke-ZeroTier $zeroTier @('join', $NetworkId)
            if ($LASTEXITCODE -ne 0) { throw "ZeroTier no pudo unirse a la red $NetworkId." }
            Start-Sleep -Seconds 2
            $networks = Invoke-ZeroTier $zeroTier @('listnetworks') 2>&1 | Out-String
        }

        $info = Invoke-ZeroTier $zeroTier @('info') 2>&1 | Out-String
    } finally {
        $ErrorActionPreference = $previous
    }
    Write-Host "`nEstado de ZeroTier:" -ForegroundColor Cyan
    Write-Host $info.Trim()
    Write-Host $networks.Trim()

    $nodeId = $null
    if ($info -match '200 info ([0-9a-fA-F]{10})') { $nodeId = $Matches[1] }

    $managedIp = $null
    $networkLine = $networks -split "`r?`n" | Where-Object { $_ -match [regex]::Escape($NetworkId) } | Select-Object -First 1
    if ($networkLine -and $networkLine -match '([0-9]{1,3}(?:\.[0-9]{1,3}){3})/\d+') { $managedIp = $Matches[1] }

    Write-Host "`nLISTO (ZeroTier + TightVNC)." -ForegroundColor Green
    if ($nodeId) { Write-Host "Node ID: $nodeId" -ForegroundColor Cyan }
    if ($managedIp) {
        Write-Host "IP ZeroTier: $managedIp" -ForegroundColor Cyan
        Write-Host "Conecta el visor VNC a: ${managedIp}:5900" -ForegroundColor Yellow
    } else {
        Write-Host '1. Autoriza este nodo en ZeroTier Central (usa el Node ID de arriba).' -ForegroundColor Yellow
        Write-Host '2. Cuando este autorizado aparecera la IP administrada; conecta el visor VNC a esa IP, puerto 5900.' -ForegroundColor Yellow
    }
    Write-Host 'Abre TightVNC Server - Control Center (System Service) y define una contrasena.' -ForegroundColor Yellow
} else {
    Write-Step 'Habilitando OpenSSH Server'
    Enable-OpenSshServer

    Write-Step 'Instalando cloudflared'
    Install-Package 'Cloudflare.cloudflared'

    $starter = Copy-CloudflareStarter
    $windowsUser = $env:USERNAME

    Write-Host "`nLISTO (Cloudflare + SSH + TightVNC)." -ForegroundColor Green
    Write-Host '1. Abre TightVNC Server - Control Center (System Service) y define una contrasena.' -ForegroundColor Yellow
    Write-Host "2. En este equipo ejecuta:" -ForegroundColor Yellow
    Write-Host "   powershell -ExecutionPolicy Bypass -File `"$starter`""
    Write-Host '3. Comparte SOLO el host *.trycloudflare.com que muestre el tunel.' -ForegroundColor Yellow
    Write-Host '4. En Linux, el tecnico ejecuta:' -ForegroundColor Yellow
    Write-Host "   ssh -N -L 5901:127.0.0.1:5900 -o 'ProxyCommand=cloudflared access ssh --hostname %h' $windowsUser@HOST.trycloudflare.com"
    Write-Host '   vncviewer localhost:5901'
    Write-Host 'La cuenta de Windows debe tener contrasena para que SSH acepte el inicio de sesion.' -ForegroundColor DarkGray
}
