#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Prepara soporte remoto en Windows con una de tres rutas:

  1) ZeroTier + TightVNC directo (recomendado si ambos usan ZeroTier).
  2) Cloudflare + SSH + TightVNC local (respaldo con autenticacion Windows).
  3) Cloudflare TCP + TightVNC directo (ideal si el usuario Windows NO tiene contrasena).

.DESCRIPTION
winget es la fuente normal. Si winget o la descarga del proveedor estan
bloqueados (por ejemplo por Fortinet), se usa el MSI exacto publicado en el
Release del repositorio y se valida su SHA-256 antes de instalar.

.PARAMETER Flow
Omite el menu: ZeroTier, Cloudflare o CloudflareVnc.

.PARAMETER NetworkId
Red de ZeroTier a la que se une el equipo.

.PARAMETER VncPassword
Contrasena de TightVNC (maximo 8 caracteres). Por defecto 1224.

.PARAMETER DisableVncAuth
Deja TightVNC sin autenticacion VNC. No recomendado fuera de una VM de prueba.

.PARAMETER ForceRelease
No intenta winget y usa directamente los MSI del Release.

.PARAMETER NoAutoStart
En el flujo Cloudflare no abre el tunel automaticamente; solo deja el lanzador listo.
#>
[CmdletBinding()]
param(
    [ValidateSet('ZeroTier', 'Cloudflare', 'CloudflareVnc')]
    [string] $Flow,

    [ValidatePattern('^[a-fA-F0-9]{16}$')]
    [string] $NetworkId = 'c1644bfd5484e1f8',

    [ValidateLength(0, 8)]
    [string] $VncPassword = '1224',

    [switch] $DisableVncAuth,

    [switch] $ForceRelease,

    [switch] $NoAutoStart
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$CommonAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
$InstallRoot = Join-Path $CommonAppData 'RemoteSupportBootstrap'
$TunnelUrlFile = Join-Path $InstallRoot 'cloudflare-url.txt'
$TunnelVncUrlFile = Join-Path $InstallRoot 'cloudflare-vnc-url.txt'
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

function Install-RemotePackage([string] $Id) {
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

function Find-TightVncServer {
    $candidates = @()
    if ($env:ProgramFiles) { $candidates += Join-Path $env:ProgramFiles 'TightVNC\tvnserver.exe' }
    $programFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    if ($programFilesX86) { $candidates += Join-Path $programFilesX86 'TightVNC\tvnserver.exe' }

    $server = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $server) { throw 'No se encontro tvnserver.exe. TightVNC no quedo instalado correctamente.' }
    return $server
}

function Get-VncPasswordHash([string] $Password) {
    # VNC cifra la contrasena con DES/ECB y una clave fija cuyos bits estan
    # invertidos respecto a la representacion estandar de DES.
    $plain = New-Object byte[] 8
    $bytes = [Text.Encoding]::ASCII.GetBytes($Password)
    [Array]::Copy($bytes, $plain, [Math]::Min(8, $bytes.Length))

    $fixedKey = [byte[]](23, 82, 107, 6, 35, 78, 88, 7)
    $key = New-Object byte[] 8
    for ($index = 0; $index -lt 8; $index++) {
        $value = 0
        for ($bit = 0; $bit -lt 8; $bit++) {
            $value = ($value -shl 1) -bor (($fixedKey[$index] -shr $bit) -band 1)
        }
        $key[$index] = [byte] $value
    }

    $des = [Security.Cryptography.DES]::Create()
    try {
        $des.Mode = [Security.Cryptography.CipherMode]::ECB
        $des.Padding = [Security.Cryptography.PaddingMode]::None
        $des.Key = $key
        $encrypted = $des.CreateEncryptor().TransformFinalBlock($plain, 0, 8)
        return ,$encrypted
    } finally {
        $des.Dispose()
    }
}

function Initialize-TightVnc([string] $ServerPath, [string] $Password, [switch] $AllowLoopback, [switch] $DisableAuth) {
    $service = Get-Service -Name tvnserver -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-Host 'Registrando TightVNC Server como servicio...' -ForegroundColor DarkGray
        & $ServerPath -install -silent
        for ($attempt = 1; $attempt -le 10; $attempt++) {
            Start-Sleep -Seconds 1
            $service = Get-Service -Name tvnserver -ErrorAction SilentlyContinue
            if ($service) { break }
        }
        if (-not $service) { throw 'TightVNC no se pudo registrar como servicio.' }
    }

    # Al detenerse, el servicio guarda su configuracion en el registro. Primero
    # lo detenemos y despues escribimos, para que nuestros valores prevalezcan.
    if ((Get-Service -Name tvnserver).Status -ne 'Stopped') {
        Write-Host 'Deteniendo TightVNC para aplicar la configuracion...' -ForegroundColor DarkGray
        Stop-Service -Name tvnserver -Force
        for ($attempt = 1; $attempt -le 20; $attempt++) {
            if ((Get-Service -Name tvnserver).Status -eq 'Stopped') { break }
            Start-Sleep -Milliseconds 500
        }
        if ((Get-Service -Name tvnserver).Status -ne 'Stopped') {
            throw 'No se pudo detener el servicio tvnserver para configurarlo.'
        }
    }

    $regCandidates = if ($ServerPath -match 'Program Files \(x86\)') {
        @('HKLM:\SOFTWARE\WOW6432Node\TightVNC\Server', 'HKLM:\SOFTWARE\TightVNC\Server')
    } else {
        @('HKLM:\SOFTWARE\TightVNC\Server', 'HKLM:\SOFTWARE\WOW6432Node\TightVNC\Server')
    }
    $regPath = $regCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $regPath) {
        $regPath = $regCandidates[0]
        New-Item -Path $regPath -Force | Out-Null
    }

    New-ItemProperty -Path $regPath -Name 'AcceptRfbConnections' -PropertyType DWord -Value 1 -Force | Out-Null
    New-ItemProperty -Path $regPath -Name 'RfbPort' -PropertyType DWord -Value 5900 -Force | Out-Null
    if ($AllowLoopback) {
        New-ItemProperty -Path $regPath -Name 'AllowLoopback' -PropertyType DWord -Value 1 -Force | Out-Null
    }

    if ($DisableAuth) {
        New-ItemProperty -Path $regPath -Name 'UseVncAuthentication' -PropertyType DWord -Value 0 -Force | Out-Null
        Write-Warning 'La autenticacion VNC queda desactivada. Usalo solo en una VM de prueba.'
    } else {
        if ([string]::IsNullOrEmpty($Password)) {
            throw 'VncPassword esta vacio. Usa una contrasena o -DisableVncAuth de forma explicita.'
        }
        [byte[]] $passwordHash = Get-VncPasswordHash $Password
        New-ItemProperty -Path $regPath -Name 'UseVncAuthentication' -PropertyType DWord -Value 1 -Force | Out-Null
        New-ItemProperty -Path $regPath -Name 'Password' -PropertyType Binary -Value $passwordHash -Force | Out-Null
    }

    Set-Service -Name tvnserver -StartupType Automatic
    Start-Service -Name tvnserver

    $listening = $false
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        if (Get-NetTCPConnection -LocalPort 5900 -State Listen -ErrorAction SilentlyContinue) {
            $listening = $true
            break
        }
        Start-Sleep -Milliseconds 500
    }
    if (-not $listening) { Write-Warning 'TightVNC esta iniciado, pero TCP/5900 todavia no aparece escuchando.' }
    return $listening
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

function Copy-CloudflareStarter([string] $FileName = 'Start-CloudflareSupport.ps1') {
    New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
    $target = Join-Path $InstallRoot $FileName
    $localCopy = if ($PSScriptRoot) { Join-Path $PSScriptRoot "scripts\$FileName" } else { $null }

    if ($localCopy -and (Test-Path -LiteralPath $localCopy)) {
        Copy-Item -LiteralPath $localCopy -Destination $target -Force
    } else {
        Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/CarlosEvCode/remote-support-bootstrap/main/scripts/$FileName" -OutFile $target
    }
    return $target
}

function Start-CloudflareTunnel([string] $StarterPath, [string] $SshUser) {
    # Ventana independiente: el tunel sigue vivo cuando termina este instalador.
    $arguments = if ($SshUser) {
        '-NoProfile -ExecutionPolicy Bypass -File "{0}" -SshUser "{1}"' -f $StarterPath, $SshUser
    } else {
        '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $StarterPath
    }
    return Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -PassThru
}

if (-not $Flow) {
    Write-Host 'Elige una ruta de soporte:' -ForegroundColor Cyan
    Write-Host '  1. ZeroTier + TightVNC directo (recomendado)'
    Write-Host '  2. Cloudflare + SSH + TightVNC (respaldo temporal; requiere clave de Windows)'
    Write-Host '  3. Cloudflare TCP + TightVNC (directo; ideal si el usuario NO tiene contrasena)'
    do {
        $choice = Read-Host 'Escribe 1, 2 o 3'
    } until ($choice -in '1', '2', '3')
    $Flow = switch ($choice) {
        '1' { 'ZeroTier' }
        '2' { 'Cloudflare' }
        '3' { 'CloudflareVnc' }
    }
}

Write-Step 'Instalando TightVNC (comun a todas las rutas)'
Install-RemotePackage 'GlavSoft.TightVNC'

Write-Step 'Configurando TightVNC'
$tvnserver = Find-TightVncServer
$allowLoopback = ($Flow -in 'Cloudflare', 'CloudflareVnc')
$vncReady = Initialize-TightVnc -ServerPath $tvnserver -Password $VncPassword `
    -AllowLoopback:$allowLoopback -DisableAuth:$DisableVncAuth

$vncAuthStatus = if ($DisableVncAuth) {
    'Autenticacion VNC: DESACTIVADA'
} else {
    "Contrasena VNC: $VncPassword"
}
$vncPortStatus = if ($vncReady) { 'TCP/5900 activo' } else { 'TCP/5900 aun no confirmado' }
$vncStatus = "$vncAuthStatus. $vncPortStatus"

if ($Flow -eq 'ZeroTier') {
    Write-Step 'Instalando ZeroTier'
    Install-RemotePackage 'ZeroTier.ZeroTierOne'
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
    Write-Host "TightVNC queda iniciado. $vncStatus" -ForegroundColor Cyan
    if ($nodeId) { Write-Host "Node ID: $nodeId" -ForegroundColor Cyan }
    if ($managedIp) {
        Write-Host "IP ZeroTier: $managedIp" -ForegroundColor Cyan
        Write-Host "Conecta el visor VNC a: ${managedIp}:5900" -ForegroundColor Yellow
    } else {
        Write-Host '1. Autoriza este nodo en ZeroTier Central (usa el Node ID de arriba).' -ForegroundColor Yellow
        Write-Host '2. Cuando este autorizado aparecera la IP administrada; conecta el visor VNC a esa IP, puerto 5900.' -ForegroundColor Yellow
    }
} else {
    Write-Step 'Habilitando OpenSSH Server'
    Enable-OpenSshServer

    Write-Step 'Instalando cloudflared'
    Install-RemotePackage 'Cloudflare.cloudflared'

    $starter = Copy-CloudflareStarter
    $windowsUser = $env:USERNAME
    $tunnelUrl = $null

    if (-not $NoAutoStart) {
        Write-Step 'Iniciando el tunel de Cloudflare'
        Remove-Item -LiteralPath $TunnelUrlFile -Force -ErrorAction SilentlyContinue
        $tunnelProcess = Start-CloudflareTunnel -StarterPath $starter -SshUser $windowsUser
        Write-Host 'Esperando el dominio *.trycloudflare.com...' -ForegroundColor DarkGray

        for ($attempt = 1; $attempt -le 30; $attempt++) {
            Start-Sleep -Seconds 1
            if (Test-Path -LiteralPath $TunnelUrlFile) {
                $candidate = (Get-Content -LiteralPath $TunnelUrlFile -Raw -ErrorAction SilentlyContinue)
                if ($candidate) { $tunnelUrl = $candidate.Trim(); break }
            }
            if ($tunnelProcess.HasExited) { break }
        }
    }

    Write-Host "`nLISTO (Cloudflare + SSH + TightVNC)." -ForegroundColor Green
    Write-Host "TightVNC queda iniciado. $vncStatus" -ForegroundColor Cyan

    if ($NoAutoStart) {
        Write-Host '1. En este equipo ejecuta:' -ForegroundColor Yellow
        Write-Host "   powershell -ExecutionPolicy Bypass -File `"$starter`""
        Write-Host '2. Comparte SOLO el host *.trycloudflare.com que muestre el tunel.' -ForegroundColor Yellow
        Write-Host '3. En Linux, el tecnico ejecuta:' -ForegroundColor Yellow
        Write-Host "   ssh -N -L 5901:127.0.0.1:5900 -o 'ProxyCommand=cloudflared access ssh --hostname %h' $windowsUser@HOST.trycloudflare.com"
        Write-Host '   vncviewer localhost:5901'
    } elseif ($tunnelUrl) {
        $tunnelHost = $tunnelUrl -replace '^https?://', ''
        Write-Host "Dominio Cloudflare: $tunnelUrl" -ForegroundColor Yellow
        Write-Host 'El tunel ya esta abierto en una ventana nueva y sigue activo.' -ForegroundColor Green
        Write-Host 'Desde Linux, el tecnico ejecuta:' -ForegroundColor Yellow
        Write-Host "   ssh -N -L 5901:127.0.0.1:5900 -o 'ProxyCommand=cloudflared access ssh --hostname %h' $windowsUser@$tunnelHost"
        Write-Host '   vncviewer localhost:5901'
        Write-Host 'Cierra la ventana del tunel o pulsa Ctrl+C alli para terminarlo.' -ForegroundColor DarkGray
    } else {
        Write-Warning 'El tunel se inicio, pero el dominio aun no aparece en el archivo de estado.'
        Write-Host 'Revisa la ventana nueva de Cloudflare o ejecuta manualmente:' -ForegroundColor Yellow
        Write-Host "   powershell -ExecutionPolicy Bypass -File `"$starter`""
    }

    Write-Host 'SSH usa la contrasena de la cuenta de Windows; una cuenta sin contrasena no podra iniciar sesion.' -ForegroundColor Yellow
} elseif ($Flow -eq 'CloudflareVnc') {
    Write-Step 'Instalando cloudflared'
    Install-RemotePackage 'Cloudflare.cloudflared'

    $starter = Copy-CloudflareStarter 'Start-CloudflareVncSupport.ps1'
    $tunnelUrl = $null

    if (-not $NoAutoStart) {
        Write-Step 'Iniciando el tunel TCP de Cloudflare para VNC'
        Remove-Item -LiteralPath $TunnelVncUrlFile -Force -ErrorAction SilentlyContinue
        $tunnelProcess = Start-CloudflareTunnel -StarterPath $starter
        Write-Host 'Esperando el dominio *.trycloudflare.com...' -ForegroundColor DarkGray

        for ($attempt = 1; $attempt -le 30; $attempt++) {
            Start-Sleep -Seconds 1
            if (Test-Path -LiteralPath $TunnelVncUrlFile) {
                $candidate = (Get-Content -LiteralPath $TunnelVncUrlFile -Raw -ErrorAction SilentlyContinue)
                if ($candidate) { $tunnelUrl = $candidate.Trim(); break }
            }
            if ($tunnelProcess.HasExited) { break }
        }
    }

    Write-Host "`nLISTO (Cloudflare TCP + TightVNC directo)." -ForegroundColor Green
    Write-Host "TightVNC queda iniciado. $vncStatus" -ForegroundColor Cyan
    Write-Host 'No requiere usuario ni contrasena de Windows.' -ForegroundColor Green

    if ($NoAutoStart) {
        Write-Host '1. En este equipo ejecuta:' -ForegroundColor Yellow
        Write-Host "   powershell -ExecutionPolicy Bypass -File `"$starter`""
        Write-Host '2. Comparte SOLO el host *.trycloudflare.com que muestre el tunel.' -ForegroundColor Yellow
        Write-Host '3. En Linux, el tecnico ejecuta:' -ForegroundColor Yellow
        Write-Host '   cloudflared access tcp --hostname HOST.trycloudflare.com --url 127.0.0.1:5901'
        Write-Host '   vncviewer localhost:5901'
    } elseif ($tunnelUrl) {
        $tunnelHost = $tunnelUrl -replace '^https?://', ''
        Write-Host "Dominio Cloudflare: $tunnelUrl" -ForegroundColor Yellow
        Write-Host 'El tunel ya esta abierto en una ventana nueva y sigue activo.' -ForegroundColor Green
        Write-Host 'Desde Linux, el tecnico ejecuta:' -ForegroundColor Yellow
        Write-Host "   1) cloudflared access tcp --hostname $tunnelHost --url 127.0.0.1:5901"
        Write-Host "   2) vncviewer localhost:5901"
        Write-Host "   Contrasena VNC: $VncPassword" -ForegroundColor Cyan
        Write-Host 'Cierra la ventana del tunel o pulsa Ctrl+C alli para terminarlo.' -ForegroundColor DarkGray
    } else {
        Write-Warning 'El tunel se inicio, pero el dominio aun no aparece en el archivo de estado.'
        Write-Host 'Revisa la ventana nueva de Cloudflare o ejecuta manualmente:' -ForegroundColor Yellow
        Write-Host "   powershell -ExecutionPolicy Bypass -File `"$starter`""
    }
}
