<#
  ImmyBot Configuration Task: "Custom Zabbix Deployment" — TEST script (separate-script mode)

  No param() block on purpose. In separate-script mode ImmyBot injects the task's
  UI parameters as variables. A param() block redeclares them as $null and hides
  the injected values, which is why $PSBoundParameters was always empty.

  Task parameters used (names must match the ImmyBot task exactly):
    HostMetadata   Text      required   e.g. Client_ACME-<token>
    Server         Uri/Text  required   e.g. zabbix.example.com or https://zabbix.example.com
    Hostname       Text      optional   default <ClientCode>-<COMPUTERNAME>
    RefreshActiveChecks Number optional default 60 (60-3600)
    EnablePSK      Boolean   optional   default false
    TLSPSKIdentity Text      required if EnablePSK
    PresharedKey   Password  required if EnablePSK (32-512 hex chars)
  ListenPort is no longer used: passive checks are disabled, so the agent does not listen.
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

    if (-not (Test-Path $ConfigPath)) { Write-Warning "Config not found: $ConfigPath"; return $false }

    if (-not $Desired['Hostname']) {
        $Desired['Hostname'] = if ($ClientCode) { "$ClientCode-$env:COMPUTERNAME" } else { $env:COMPUTERNAME }
    }

    # Gather every occurrence of each managed key (duplicates count as drift)
    $found = @{}
    foreach ($line in Get-Content $ConfigPath) {
        if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
        $k, $v = $line -split '\s*=\s*', 2
        $k = $k.Trim()
        if ($ManagedKeys -contains $k) {
            if (-not $found.ContainsKey($k)) { $found[$k] = @() }
            $found[$k] += $v.Trim()
        }
    }

    $ok = $true
    foreach ($key in $ManagedKeys) {
        $vals = @($found[$key] | Where-Object { $null -ne $_ })
        if ($DesiredKeys -contains $key) {
            $expected = [string]$Desired[$key]
            if ($vals.Count -ne 1 -or $vals[0] -ne $expected) {
                Write-Warning "$key`: expected '$expected', found [$($vals -join ' | ')]"
                $ok = $false
            }
        } elseif ($vals.Count -gt 0) {
            Write-Warning "$key should not be set, found [$($vals -join ' | ')]"
            $ok = $false
        }
    }

    if ($EnablePSK) {
        $cur = if (Test-Path $PSKFile) { (Get-Content $PSKFile -Raw).Trim() } else { $null }
        if ($cur -ne $PSK) { Write-Warning 'PSK file missing or content differs'; $ok = $false }
    }

    $svc = Get-Service -Name 'Zabbix Agent 2' -ErrorAction SilentlyContinue
    if (-not $svc) { Write-Warning 'Service "Zabbix Agent 2" not found'; $ok = $false }
    elseif ($svc.Status -ne 'Running') { Write-Warning "Service is $($svc.Status)"; $ok = $false }
    elseif ($svc.StartType -ne 'Automatic') { Write-Warning "Service StartType is $($svc.StartType)"; $ok = $false }

    return $ok
}
