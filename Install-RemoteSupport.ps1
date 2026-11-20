#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Instala la ruta alternativa de soporte remoto: ZeroTier + SSH + VNC local,
y prepara un Quick Tunnel temporal de Cloudflare como respaldo.

.DESCRIPTION
VNC no se publica a Internet. El tecnico entra por SSH y reenvia su puerto
local 5901 hacia 127.0.0.1:5900 de este equipo.
#>
[CmdletBinding()]
param(
    [ValidatePattern('^[a-fA-F0-9]{16}$')]
    [string] $NetworkId = 'c1644bfd5484e1f8',
    [switch] $SkipVnc,
    [switch] $SkipCloudflared
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$InstallRoot = Join-Path $env:ProgramData 'RemoteSupportBootstrap'
$RepoBase = 'https://raw.githubusercontent.com/CarlosEvCode/remote-support-bootstrap/main'

function Write-Step([string] $Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Invoke-InstallerDownload([string] $Uri, [string] $Destination) {
    Invoke-WebRequest -Uri $Uri -OutFile $Destination
    $signature = Get-AuthenticodeSignature -FilePath $Destination
    if ($signature.Status -ne 'Valid') {
        throw "La firma Authenticode no es valida para $Uri. Estado: $($signature.Status)"
    }
}

function Install-Msi([string] $Path) {
    $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', "`"$Path`"", '/qn', '/norestart') -Wait -PassThru
    if ($process.ExitCode -notin 0, 3010) {
        throw "MSI fallo con codigo $($process.ExitCode): $Path"
    }
    if ($process.ExitCode -eq 3010) { Write-Warning 'Windows solicita reiniciar para completar una instalacion.' }
}

function Get-ZeroTierCli {
    $candidates = @(
        (Join-Path $env:ProgramData 'ZeroTier\One\zerotier-cli.bat'),
        (Join-Path $env:ProgramData 'ZeroTier\One\zerotier-cli.exe')
    )
    $result = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $result) { throw 'No se encontro zerotier-cli despues de instalar ZeroTier.' }
    return $result
}

function Get-CloudflaredExe {
    $command = Get-Command cloudflared.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $candidates = @(
        "$env:ProgramFiles\cloudflared\cloudflared.exe",
        "${env:ProgramFiles(x86)}\cloudflared\cloudflared.exe",
        'C:\Cloudflared\bin\cloudflared.exe'
    )
    return ($candidates | Where-Object { Test-Path $_ } | Select-Object -First 1)
}

New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null

Write-Step 'Habilitando OpenSSH Server'
$sshCapability = Get-WindowsCapability -Online | Where-Object Name -eq 'OpenSSH.Server~~~~0.0.1.0'
if ($sshCapability.State -ne 'Installed') {
    Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' | Out-Null
}
Set-Service -Name sshd -StartupType Automatic
Start-Service -Name sshd

Write-Step 'Instalando ZeroTier'
$zeroTierCli = $null
try { $zeroTierCli = Get-ZeroTierCli } catch { }
if (-not $zeroTierCli) {
    $zeroTierMsi = Join-Path $env:TEMP 'ZeroTier-One.msi'
    Invoke-InstallerDownload -Uri 'https://download.zerotier.com/dist/ZeroTier%20One.msi' -Destination $zeroTierMsi
    Install-Msi -Path $zeroTierMsi
    $zeroTierCli = Get-ZeroTierCli
}
Start-Service -Name 'ZeroTierOneService' -ErrorAction SilentlyContinue
& $zeroTierCli join $NetworkId
if ($LASTEXITCODE -ne 0) { throw "ZeroTier no pudo unirse a la red $NetworkId." }

# No dejamos SSH abierto en LAN/Internet. Solo entra por la interfaz ZeroTier.
Write-Step 'Restringiendo SSH a la interfaz ZeroTier'
$zeroTierAdapter = Get-NetAdapter -IncludeHidden | Where-Object {
    $_.InterfaceDescription -match 'ZeroTier' -or $_.Name -match 'ZeroTier'
} | Select-Object -First 1
if (-not $zeroTierAdapter) { throw 'No se encontro el adaptador ZeroTier.' }
Disable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
Get-NetFirewallRule -DisplayName 'Remote Support SSH via ZeroTier' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName 'Remote Support SSH via ZeroTier' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 22 -InterfaceAlias $zeroTierAdapter.Name -Profile Any | Out-Null

if (-not $SkipCloudflared) {
    Write-Step 'Instalando cloudflared para el respaldo temporal'
    $cloudflared = Get-CloudflaredExe
    if (-not $cloudflared) {
        $cloudflaredMsi = Join-Path $env:TEMP 'cloudflared-windows-amd64.msi'
        Invoke-InstallerDownload -Uri 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.msi' -Destination $cloudflaredMsi
        Install-Msi -Path $cloudflaredMsi
    }
}

if (-not $SkipVnc) {
    Write-Step 'Instalando TightVNC 4'
    $tightVncMsi = Join-Path $env:TEMP 'tightvnc-4.0.2-x64.msi'
    Invoke-InstallerDownload -Uri 'https://www.tightvnc.com/download/4.0.2/tightvnc-4.0.2-x64.msi' -Destination $tightVncMsi
    # La instalacion se deja interactiva: la persona local debe elegir una contrasena.
    Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', "`"$tightVncMsi`"") -Wait
}

Write-Step 'Copiando el iniciador de Cloudflare'
$scriptSource = Join-Path $PSScriptRoot 'scripts\Start-CloudflareSupport.ps1'
$scriptTarget = Join-Path $InstallRoot 'Start-CloudflareSupport.ps1'
if (Test-Path $scriptSource) {
    Copy-Item -Force $scriptSource $scriptTarget
} else {
    Invoke-WebRequest -Uri "$RepoBase/scripts/Start-CloudflareSupport.ps1" -OutFile $scriptTarget
}

Write-Host ''
Write-Host 'INSTALACION BASE COMPLETA' -ForegroundColor Green
Write-Host "1. Autoriza este equipo en ZeroTier Central (Network ID: $NetworkId)."
Write-Host '2. En TightVNC configura una contrasena fuerte y confirma que no exista una regla de firewall que abra TCP/5900.'
Write-Host '3. El tecnico se conecta por SSH a la IP administrada de ZeroTier y crea el tunel VNC.'
Write-Host "4. Para respaldo temporal ejecuta: powershell -ExecutionPolicy Bypass -File `"$scriptTarget`""
Write-Host ''
Write-Host 'Estado de ZeroTier:' -ForegroundColor Cyan
& $zeroTierCli listnetworks
Write-Host ''
Write-Host 'Estado de SSH:' -ForegroundColor Cyan
Get-Service sshd | Format-Table -AutoSize
