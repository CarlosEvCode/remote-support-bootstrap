#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Revierte exclusivamente los componentes instalados por Install-RemoteSupport.

.DESCRIPTION
Lee el registro de estado creado por el bootstrap. Si un componente ya existia,
no se marca y por tanto no se desinstala. Tambien elimina solo la regla de
firewall creada por este proyecto.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param()

$ErrorActionPreference = 'Stop'
$InstallRoot = Join-Path $env:ProgramData 'RemoteSupportBootstrap'
$StatePath = Join-Path $InstallRoot 'bootstrap-state.json'

function Get-UninstallEntry([string] $NamePattern) {
    $paths = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    Get-ItemProperty $paths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match $NamePattern } |
        Select-Object -First 1
}

function Uninstall-RecordedApp([string] $NamePattern, [string] $Label) {
    $entry = Get-UninstallEntry $NamePattern
    if (-not $entry) { Write-Warning "$Label ya no figura instalado; se omitira."; return }
    if (-not $PSCmdlet.ShouldProcess($Label, 'desinstalar')) { return }
    # Las MSI registran su ProductCode como nombre de la clave, la via segura
    # para desinstalarlas sin reinterpretar una cadena de comandos arbitraria.
    if ($entry.PSChildName -match '^\{[0-9A-Fa-f-]+\}$') {
        $process = Start-Process msiexec.exe -ArgumentList @('/x', $entry.PSChildName, '/qn', '/norestart') -Wait -PassThru
        if ($process.ExitCode -notin 0, 3010, 1605) { throw "No se pudo desinstalar $Label (codigo $($process.ExitCode))." }
    } else {
        throw "No es seguro ejecutar el desinstalador no-MSI de $Label automaticamente. Desinstalalo desde Aplicaciones instaladas."
    }
}

if (-not (Test-Path $StatePath)) {
    throw "No existe $StatePath. Para no eliminar software ajeno, no se hara ningun cambio."
}
$state = Get-Content $StatePath -Raw | ConvertFrom-Json

if ($PSCmdlet.ShouldProcess('Remote Support SSH via ZeroTier', 'eliminar regla de firewall')) {
    Get-NetFirewallRule -DisplayName 'Remote Support SSH via ZeroTier' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
}
if ($null -ne $state.DefaultOpenSshRuleWasEnabled) {
    if ($PSCmdlet.ShouldProcess('OpenSSH-Server-In-TCP', 'restaurar su estado anterior')) {
        if ($state.DefaultOpenSshRuleWasEnabled) { Enable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue }
        else { Disable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue }
    }
}

if ($state.ZeroTierJoinedByBootstrap) {
    $cli = @("$env:ProgramData\ZeroTier\One\zerotier-cli.bat", "$env:ProgramData\ZeroTier\One\zerotier-cli.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($cli -and $PSCmdlet.ShouldProcess("red ZeroTier $($state.NetworkId)", 'abandonar')) { & $cli leave $state.NetworkId }
}
if ($state.TightVncInstalledByBootstrap) { Uninstall-RecordedApp 'TightVNC' 'TightVNC' }
if ($state.CloudflaredInstalledByBootstrap) { Uninstall-RecordedApp 'cloudflared' 'cloudflared' }
if ($state.ZeroTierInstalledByBootstrap) { Uninstall-RecordedApp 'ZeroTier' 'ZeroTier' }
if ($state.OpenSshInstalledByBootstrap -and $PSCmdlet.ShouldProcess('OpenSSH Server', 'quitar capacidad de Windows')) {
    Remove-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' | Out-Null
} elseif ($null -ne $state.SshdOriginalStartMode -and $PSCmdlet.ShouldProcess('sshd', 'restaurar estado anterior')) {
    $startup = switch ($state.SshdOriginalStartMode) { 'Auto' { 'Automatic' } 'Manual' { 'Manual' } 'Disabled' { 'Disabled' } default { $null } }
    if ($startup) { Set-Service -Name sshd -StartupType $startup -ErrorAction SilentlyContinue }
    if (-not $state.SshdWasRunning) { Stop-Service -Name sshd -ErrorAction SilentlyContinue }
}
if ($PSCmdlet.ShouldProcess($InstallRoot, 'eliminar estado, script copiado y cache')) {
    Remove-Item -LiteralPath $InstallRoot -Recurse -Force
}
Write-Host 'Cambios del bootstrap revertidos.' -ForegroundColor Green
