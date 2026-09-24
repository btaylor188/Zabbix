<#
  ImmyBot Configuration Task: "Custom Zabbix Deployment" — SET script (separate-script mode)

  No param() block on purpose; see the Test script header. The resolve block below must
  stay identical to the one in the Test script.

  On the endpoint: back up the conf, strip every managed key, append one managed block,
  write the PSK file (ACL: SYSTEM + Administrators only), validate with
  `zabbix_agent2.exe -T`, restart the service. If validation or the restart fails, the
  backup is restored and the task throws.
#>

# ---------- resolve parameters (keep identical in Test and Set) ----------
$ActivePort    = 10051
$ConfigPath    = 'C:\Program Files\Zabbix Agent 2\zabbix_agent2.conf'
$PSKFile       = 'C:\Program Files\Zabbix Agent 2\zabbix_agent2.psk'

function Get-TaskParam([string]$Name, $Default = $null) {
    $v = Get-Variable -Name $Name -ValueOnly -ErrorAction SilentlyContinue
    if ($null -eq $v -or ($v -is [string] -and [string]::IsNullOrWhiteSpace($v))) { return $Default }
    return $v
}

$injected = 'Server','Hostname','HostMetadata','RefreshActiveChecks','EnablePSK','TLSPSKIdentity','PresharedKey' |
    Where-Object { $null -ne (Get-TaskParam $_) }
Write-Host "Task params received: $(if ($injected) { $injected -join ', ' } else { '(none)' }); Tenant='$TenantName'"

$ServerRaw = [string](Get-TaskParam 'Server')
if (-not $ServerRaw) {
    Write-Warning 'Server not supplied: set the Server task parameter (e.g. zabbix.example.com).'
    return $false
}
$ZbxServer = if ($ServerRaw -match '://') { ([Uri]$ServerRaw).Host } else { ($ServerRaw -split ':')[0].Trim() }
if (-not $ZbxServer) { throw "Could not parse a host from Server='$ServerRaw'" }

$HostMetadata = [string](Get-TaskParam 'HostMetadata')
if (-not $HostMetadata) {
    Write-Warning 'HostMetadata not supplied: the task parameter is empty for this target.'
    return $false
}
$ClientCode = if ($HostMetadata -match '^Client_([A-Za-z0-9]+)[-_]') { $Matches[1] } else { $null }
if (-not $ClientCode) { Write-Warning "HostMetadata '$HostMetadata' does not match Client_<CODE>-<token>; hostname will not be prefixed." }

$HostnameOverride = [string](Get-TaskParam 'Hostname')
# A literal '$env:COMPUTERNAME' typed into the ImmyBot UI arrives as text, not expanded; treat it as auto
if ($HostnameOverride -match '^\s*\$env:COMPUTERNAME\s*$') { $HostnameOverride = '' }
if ($HostnameOverride -and $HostnameOverride -notmatch '^[0-9A-Za-z .\-_]{1,128}$') {
    throw "Hostname '$HostnameOverride' contains characters Zabbix rejects (allowed: letters, digits, space, . - _)"
}
$Refresh = [int](Get-TaskParam 'RefreshActiveChecks' 60)
if ($Refresh -lt 60 -or $Refresh -gt 3600) { throw "RefreshActiveChecks must be 60-3600 (got $Refresh)" }

$pskRaw    = Get-TaskParam 'EnablePSK' $false
$EnablePSK = if ($pskRaw -is [string]) { $pskRaw -match '^(true|1|yes)$' } else { [bool]$pskRaw }
$PSKIdentity = [string](Get-TaskParam 'TLSPSKIdentity')
$PSK = Get-TaskParam 'PresharedKey'
if ($PSK -is [securestring]) { $PSK = [Net.NetworkCredential]::new('', $PSK).Password }
$PSK = [string]$PSK
if ($EnablePSK) {
    if (-not $PSKIdentity -or -not $PSK) { throw 'EnablePSK requires TLSPSKIdentity and PresharedKey' }
    if ($PSK -notmatch '^[0-9a-fA-F]{32,512}$') { throw 'PresharedKey must be 32-512 hex characters' }
}

# Every key this task owns. Existing instances are stripped before the managed block
# is written. StartAgents is listed only so an old invalid entry gets removed.
$ManagedKeys = @('Server','ServerActive','Hostname','HostMetadata','RefreshActiveChecks','StartAgents',
                 'TLSConnect','TLSAccept','TLSPSKIdentity','TLSPSKFile')

$Desired = [ordered]@{
    Server              = ''                              # empty = passive checks off, no listener (agent 2)
    ServerActive        = "$($ZbxServer):$ActivePort"
    Hostname            = $HostnameOverride               # blank -> resolved on endpoint
    HostMetadata        = $HostMetadata
    RefreshActiveChecks = $Refresh
    TLSConnect          = if ($EnablePSK) { 'psk' } else { 'unencrypted' }
    TLSAccept           = if ($EnablePSK) { 'psk' } else { 'unencrypted' }
}
if ($EnablePSK) {
    $Desired['TLSPSKIdentity'] = $PSKIdentity
    $Desired['TLSPSKFile']     = $PSKFile
}
$DesiredKeys = [string[]]$Desired.Keys
# -------------------------------------------------------------------------
Invoke-ImmyCommand {
    $Desired     = $using:Desired
    $DesiredKeys = $using:DesiredKeys
    $ManagedKeys = $using:ManagedKeys
    $ConfigPath  = $using:ConfigPath
    $ClientCode  = $using:ClientCode
    $EnablePSK   = $using:EnablePSK
    $PSK         = $using:PSK
    $PSKFile     = $using:PSKFile

    $ServiceName = 'Zabbix Agent 2'
    $AgentDir    = Split-Path $ConfigPath -Parent
    $AgentExe    = Join-Path $AgentDir 'zabbix_agent2.exe'
    $Backup      = "$ConfigPath.immybak"
    $Marker      = '# --- ImmyBot managed parameters (do not edit by hand) ---'

    if (-not (Test-Path $ConfigPath)) { throw "Zabbix config not found at $ConfigPath (is the agent installed?)" }
    if (-not (Test-Path $AgentExe))   { throw "Agent binary not found at $AgentExe" }

    if (-not $Desired['Hostname']) {
        $Desired['Hostname'] = if ($ClientCode) { "$ClientCode-$env:COMPUTERNAME" } else { $env:COMPUTERNAME }
    }

    $PSKBackup = "$PSKFile.immybak"
    Copy-Item $ConfigPath $Backup -Force
    $hadPSK = Test-Path $PSKFile
    if ($hadPSK) { Copy-Item $PSKFile $PSKBackup -Force }

    function Restore-Backup([switch]$Restart) {
        Copy-Item $Backup $ConfigPath -Force
        if ($hadPSK) { Copy-Item $PSKBackup $PSKFile -Force }
        if ($Restart) { Restart-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue }
    }

    # Keep comments and unmanaged keys; drop every managed key and any prior marker line
    $kept = @(Get-Content $ConfigPath | Where-Object {
        if ($_ -eq $Marker) { return $false }
        if ($_ -match '^\s*#' -or $_ -notmatch '=') { return $true }
        $key = ($_ -split '\s*=\s*', 2)[0].Trim()
        return -not ($ManagedKeys -contains $key)
    })
    # Trim trailing blank lines so repeated runs don't grow the file
    $last = $kept.Count - 1
    while ($last -ge 0 -and [string]::IsNullOrWhiteSpace($kept[$last])) { $last-- }
    $kept = if ($last -ge 0) { $kept[0..$last] } else { @() }

    $block = @('', $Marker)
    foreach ($key in $DesiredKeys) { $block += "$key=$($Desired[$key])" }

    if ($EnablePSK) {
        [IO.File]::WriteAllText($PSKFile, $PSK)   # no trailing newline, no BOM
        & icacls.exe $PSKFile /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "icacls failed on $PSKFile (exit $LASTEXITCODE)" }
    }

    # UTF-8 without BOM
    [IO.File]::WriteAllLines($ConfigPath, [string[]]($kept + $block))

    # Validate before touching the running service. Run from the agent dir so relative Include= paths resolve.
    Push-Location $AgentDir
    $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'   # stderr from a native exe must not become a terminating error
    try   { $out = (& $AgentExe -T -c $ConfigPath 2>&1 | ForEach-Object { "$_" }) -join "`n"; $rc = $LASTEXITCODE }
    finally { $ErrorActionPreference = $eap; Pop-Location }
    if ($rc -ne 0) {
        Restore-Backup
        throw "zabbix_agent2 -T rejected the new config (exit $rc); backup restored.`n$out"
    }

    Set-Service -Name $ServiceName -StartupType Automatic
    try {
        Restart-Service -Name $ServiceName -Force -ErrorAction Stop
        (Get-Service -Name $ServiceName).WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
    } catch {
        Restore-Backup -Restart
        throw "Service failed to start with the new config; backup restored. $_"
    }

    Write-Host "Zabbix Agent 2 configured: Hostname=$($Desired['Hostname']) ServerActive=$($Desired['ServerActive']) PSK=$EnablePSK"
}
