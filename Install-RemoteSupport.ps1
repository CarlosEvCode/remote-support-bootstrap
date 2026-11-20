#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Prepara ZeroTier + OpenSSH + TightVNC y el respaldo temporal Cloudflare.

.DESCRIPTION
Los instaladores se conservan en una cache persistente para que una segunda
ejecucion (o una instalacion desde USB) no dependa otra vez de Internet.
Las MSI se validan con Authenticode antes de ejecutarse.
#>
[CmdletBinding()]
param(
    [ValidatePattern('^[a-fA-F0-9]{16}$')]
    [string] $NetworkId = 'c1644bfd5484e1f8',
    [switch] $SkipVnc,
    [switch] $SkipCloudflared,
    # Carpeta opcional (por ejemplo, una USB) que contiene las MSI indicadas abajo.
    [string] $InstallerSource,
    [switch] $RefreshInstallers,
    # Los assets del ultimo GitHub Release se prueban antes que el proveedor.
    [string] $ReleaseBaseUrl = 'https://github.com/CarlosEvCode/remote-support-bootstrap/releases/latest/download'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$CommonAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
if ([string]::IsNullOrWhiteSpace($CommonAppData)) { throw 'Windows no devolvio la carpeta ProgramData requerida para la instalacion.' }
if ($InstallerSource -and -not (Test-Path -LiteralPath $InstallerSource -PathType Container)) {
    throw "InstallerSource no es una carpeta existente: $InstallerSource"
}
$InstallRoot = Join-Path -Path $CommonAppData -ChildPath 'RemoteSupportBootstrap'
$InstallerCache = Join-Path $InstallRoot 'installers'
$StatePath = Join-Path $InstallRoot 'bootstrap-state.json'
$RepoBase = 'https://raw.githubusercontent.com/CarlosEvCode/remote-support-bootstrap/main'

function Write-Step([string] $Message) { Write-Host "`n==> $Message" -ForegroundColor Cyan }

function Test-SignedInstaller([string] $Path) {
    $signature = Get-AuthenticodeSignature -FilePath $Path
    if ($signature.Status -ne 'Valid') {
        throw "La firma Authenticode no es valida para $Path. Estado: $($signature.Status)"
    }
}

function Save-State { $script:state | ConvertTo-Json | Set-Content -Path $StatePath -Encoding UTF8 }

function Get-Installer([string] $FileName, [string[]] $Uris) {
    $cached = Join-Path $InstallerCache $FileName
    $external = if ($InstallerSource) { Join-Path $InstallerSource $FileName }

    if ($external -and (Test-Path $external)) {
        Write-Host "Usando instalador local: $external" -ForegroundColor DarkGray
        Test-SignedInstaller $external
        Copy-Item -Force $external $cached
        return $cached
    }
    if ((Test-Path $cached) -and -not $RefreshInstallers) {
        try {
            Test-SignedInstaller $cached
            Write-Host "Usando cache: $cached" -ForegroundColor DarkGray
            return $cached
        } catch {
            Write-Warning 'La copia en cache no es valida; se descargara de nuevo.'
            Remove-Item -Force $cached
        }
    }

    Write-Host "Descargando $FileName (solo esta vez; luego queda en cache)..." -ForegroundColor DarkGray
    $partial = "$cached.download"
    Remove-Item -Force $partial -ErrorAction SilentlyContinue
    $lastError = $null
    foreach ($uri in $Uris) {
      foreach ($attempt in 1..3) {
        try {
            Invoke-WebRequest -Uri $Uri -OutFile $partial -UseBasicParsing
            Test-SignedInstaller $partial
            Move-Item -Force $partial $cached
            return $cached
        } catch {
            $lastError = $_
            Remove-Item -Force $partial -ErrorAction SilentlyContinue
            # Un release que aun no tiene este asset no debe añadir 6 s por intento.
            if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { break }
            if ($attempt -lt 3) { Start-Sleep -Seconds (2 * $attempt) }
        }
      }
    }
    throw "No se pudo obtener $FileName desde ninguna fuente. $lastError"
}

function Install-Msi([string] $Path, [switch] $Interactive) {
    $arguments = @('/i', "`"$Path`"")
    if (-not $Interactive) { $arguments += @('/qn', '/norestart') }
    $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $arguments -Wait -PassThru
    if ($process.ExitCode -notin 0, 3010) { throw "MSI fallo con codigo $($process.ExitCode): $Path" }
    if ($process.ExitCode -eq 3010) { Write-Warning 'Windows solicita reiniciar para completar una instalacion.' }
}

function Get-ZeroTierCli {
    $candidates = @(
        (Join-Path $CommonAppData 'ZeroTier\One\zerotier-cli.bat'),
        (Join-Path $CommonAppData 'ZeroTier\One\zerotier-cli.exe'),
        (Join-Path $CommonAppData 'ZeroTier\One\zerotier-one_x64.exe'),
        (Join-Path $CommonAppData 'ZeroTier\One\zerotier-one_x86.exe')
    )
    $result = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $result) { throw 'No se encontro zerotier-cli despues de instalar ZeroTier.' }
    $result
}

function Invoke-ZeroTierCli([string] $Cli, [string[]] $Arguments) {
    # Las MSI recientes incluyen zerotier-one_x64.exe, no zerotier-cli.bat.
    # -q activa su personalidad compatible con zerotier-cli.
    if ((Split-Path -Leaf $Cli) -match '^zerotier-one_') { & $Cli -q @Arguments }
    else { & $Cli @Arguments }
}

function Get-CloudflaredExe {
    $command = Get-Command cloudflared.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $candidates = @("$env:ProgramFiles\cloudflared\cloudflared.exe", "${env:ProgramFiles(x86)}\cloudflared\cloudflared.exe", 'C:\Cloudflared\bin\cloudflared.exe')
    $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}

function Test-TightVncInstalled { [bool](Get-Service -Name 'tvnserver' -ErrorAction SilentlyContinue) }

function Test-ZeroTierNetwork([string] $Cli, [string] $Id) {
    $networks = Invoke-ZeroTierCli -Cli $Cli -Arguments @('listnetworks') 2>&1
    if ($LASTEXITCODE -ne 0) { throw "No se pudo consultar las redes de ZeroTier: $networks" }
    [bool]($networks | Select-String -SimpleMatch $Id -Quiet)
}

function Get-ZeroTierAdapter {
    foreach ($attempt in 1..15) {
        $adapter = Get-NetAdapter -IncludeHidden | Where-Object { $_.InterfaceDescription -match 'ZeroTier' -or $_.Name -match 'ZeroTier' } | Select-Object -First 1
        if ($adapter) { return $adapter }
        Start-Sleep -Seconds 2
    }
    throw 'El adaptador ZeroTier no aparecio tras 30 segundos. Reinicia el servicio ZeroTierOneService y vuelve a ejecutar el instalador.'
}

New-Item -ItemType Directory -Force -Path $InstallRoot, $InstallerCache | Out-Null
$state = [ordered]@{ Version = 1; NetworkId = $NetworkId; OpenSshInstalledByBootstrap = $false; ZeroTierInstalledByBootstrap = $false; ZeroTierJoinedByBootstrap = $false; CloudflaredInstalledByBootstrap = $false; TightVncInstalledByBootstrap = $false }
if (Test-Path $StatePath) { try { $state = Get-Content $StatePath -Raw | ConvertFrom-Json } catch { Write-Warning 'El estado anterior no es legible; se creara uno nuevo.' } }

Write-Step 'Comprobando OpenSSH Server'
$sshCapability = Get-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'
if ($sshCapability.State -ne 'Installed') {
    Write-Host 'OpenSSH no esta instalado; Windows puede tardar al descargar esta capacidad.' -ForegroundColor DarkGray
    Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' | Out-Null
    $state.OpenSshInstalledByBootstrap = $true; Save-State
}
$sshd = Get-CimInstance Win32_Service -Filter "Name='sshd'"
if (-not ($state.PSObject.Properties.Name -contains 'SshdOriginalStartMode')) {
    $state | Add-Member -NotePropertyName SshdOriginalStartMode -NotePropertyValue $sshd.StartMode
    $state | Add-Member -NotePropertyName SshdWasRunning -NotePropertyValue ($sshd.State -eq 'Running')
    Save-State
}
Set-Service -Name sshd -StartupType Automatic
if ((Get-Service sshd).Status -ne 'Running') { Start-Service sshd }

Write-Step 'Comprobando ZeroTier'
$zeroTierCli = $null
try { $zeroTierCli = Get-ZeroTierCli } catch { }
if (-not $zeroTierCli) {
    $zeroTierMsi = Get-Installer 'ZeroTier-One.msi' @("$ReleaseBaseUrl/ZeroTier-One.msi", 'https://download.zerotier.com/dist/ZeroTier%20One.msi')
    Install-Msi $zeroTierMsi
    $state.ZeroTierInstalledByBootstrap = $true; Save-State
    $zeroTierCli = Get-ZeroTierCli
}
Set-Service -Name 'ZeroTierOneService' -StartupType Automatic -ErrorAction SilentlyContinue
$zeroTierService = Get-Service 'ZeroTierOneService' -ErrorAction Stop
if ($zeroTierService.Status -ne 'Running') { Start-Service 'ZeroTierOneService' }
if (Test-ZeroTierNetwork $zeroTierCli $NetworkId) {
    Write-Host "Este equipo ya pertenece a la red $NetworkId." -ForegroundColor DarkGray
} else {
    Invoke-ZeroTierCli -Cli $zeroTierCli -Arguments @('join', $NetworkId)
    if ($LASTEXITCODE -ne 0) { throw "ZeroTier no pudo unirse a la red $NetworkId." }
    $state.ZeroTierJoinedByBootstrap = $true; Save-State
}

Write-Step 'Restringiendo SSH a la interfaz ZeroTier'
$zeroTierAdapter = Get-ZeroTierAdapter
if (-not ($state.PSObject.Properties.Name -contains 'DefaultOpenSshRuleWasEnabled')) {
    $defaultRule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
    $state | Add-Member -NotePropertyName DefaultOpenSshRuleWasEnabled -NotePropertyValue [bool]($defaultRule.Enabled -contains 'True')
    Save-State
}
Disable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
Get-NetFirewallRule -DisplayName 'Remote Support SSH via ZeroTier' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName 'Remote Support SSH via ZeroTier' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 22 -InterfaceAlias $zeroTierAdapter.Name -Profile Any | Out-Null

if (-not $SkipCloudflared) {
    Write-Step 'Comprobando cloudflared para el respaldo temporal'
    $cloudflared = Get-CloudflaredExe
    if (-not $cloudflared) {
        $cloudflaredMsi = Get-Installer 'cloudflared-windows-amd64.msi' @("$ReleaseBaseUrl/cloudflared-windows-amd64.msi", 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.msi')
        Install-Msi $cloudflaredMsi
        if (-not (Get-CloudflaredExe)) { throw 'cloudflared no se encontro despues de instalarlo.' }
        $state.CloudflaredInstalledByBootstrap = $true; Save-State
    }
}

if (-not $SkipVnc) {
    Write-Step 'Comprobando TightVNC 4'
    if (Test-TightVncInstalled) {
        Write-Host 'TightVNC ya esta instalado; no se abrira el instalador otra vez.' -ForegroundColor DarkGray
    } else {
        $tightVncMsi = Get-Installer 'tightvnc-4.0.2-x64.msi' @("$ReleaseBaseUrl/tightvnc-4.0.2-x64.msi", 'https://www.tightvnc.com/download/4.0.2/tightvnc-4.0.2-x64.msi')
        Write-Host 'El instalador es interactivo para que la contrasena no se guarde en ningun script.' -ForegroundColor Yellow
        Install-Msi $tightVncMsi -Interactive
        if (Test-TightVncInstalled) { $state.TightVncInstalledByBootstrap = $true; Save-State }
    }
}

Write-Step 'Copiando el iniciador de Cloudflare'
# Con `irm ... | iex` no hay archivo en disco y $PSScriptRoot esta vacio.
$scriptSource = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'scripts\Start-CloudflareSupport.ps1' } else { $null }
$scriptTarget = Join-Path $InstallRoot 'Start-CloudflareSupport.ps1'
if ($scriptSource -and (Test-Path $scriptSource)) { Copy-Item -Force $scriptSource $scriptTarget } else { Invoke-WebRequest -Uri "$RepoBase/scripts/Start-CloudflareSupport.ps1" -OutFile $scriptTarget -UseBasicParsing }
$uninstallSource = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'Uninstall-RemoteSupport.ps1' } else { $null }
$uninstallTarget = Join-Path $InstallRoot 'Uninstall-RemoteSupport.ps1'
if ($uninstallSource -and (Test-Path $uninstallSource)) { Copy-Item -Force $uninstallSource $uninstallTarget } else { Invoke-WebRequest -Uri "$RepoBase/Uninstall-RemoteSupport.ps1" -OutFile $uninstallTarget -UseBasicParsing }

Write-Host "`nINSTALACION BASE COMPLETA" -ForegroundColor Green
Write-Host "1. Autoriza este equipo en ZeroTier Central (Network ID: $NetworkId)."
Write-Host '2. En TightVNC configura una contrasena fuerte y no abras TCP/5900 en el firewall.'
Write-Host '3. Para respaldo temporal ejecuta:'
Write-Host "   powershell -ExecutionPolicy Bypass -File `"$scriptTarget`""
Write-Host '4. Para revertir solo los cambios de este bootstrap ejecuta:'
Write-Host "   powershell -ExecutionPolicy Bypass -File `"$uninstallTarget`""
Write-Host "`nCache de instaladores: $InstallerCache" -ForegroundColor Cyan
Write-Host 'Puedes copiar esa carpeta a una USB y reutilizarla con -InstallerSource X:\carpeta.' -ForegroundColor Cyan
Write-Host "`nEstado de ZeroTier:" -ForegroundColor Cyan
Invoke-ZeroTierCli -Cli $zeroTierCli -Arguments @('listnetworks')
Write-Host "`nEstado de SSH:" -ForegroundColor Cyan
Get-Service sshd | Format-Table -AutoSize
