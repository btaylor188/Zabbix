<#
  ImmyBot Configuration Task: "Custom Zabbix Deployment" - TEST script (separate-script mode)

  No param() block on purpose. In separate-script mode ImmyBot injects the task's
  UI parameters as variables. A param() block redeclares them as $null and hides
  the injected values.

  Task parameters used (names must match the ImmyBot task exactly):
    HostMetadata        Text      required   client code, e.g. CleverpathIT or K2_Ambassadors (selects host group Clients/<CODE>, case-sensitive)
    Server              Uri/Text  required   e.g. zabbix.example.com or https://zabbix.example.com
    Hostname            Text      optional   default <ClientCode>-<COMPUTERNAME>
    RefreshActiveChecks Number    optional   default 60 (60-3600)
    EnablePSK           Boolean   optional   default false  (per-tenant rollout switch)
    ZabbixApiUrl        Uri       optional   default https://<Server host>/api_jsonrpc.php
    ZabbixApiToken      Password  required if EnablePSK
    TemplateIds         Text      required if EnablePSK and host must be created; comma-separated template IDs
    ProxyId             Text      optional   proxy ID if the tenant is monitored by a proxy

  Per-host PSK: generated on the endpoint, stored in zabbix_agent2.host.psk, pushed to Zabbix
  via API. PSK identity = Zabbix Hostname. The legacy shared zabbix_agent2.psk is removed by Set.
#>

# ---------- resolve parameters (keep identical in Test and Set) ----------
$ActivePort    = 10051
$ConfigPath    = 'C:\Program Files\Zabbix Agent 2\zabbix_agent2.conf'
$PSKFile       = 'C:\Program Files\Zabbix Agent 2\zabbix_agent2.host.psk'
$LegacyPSKFile = 'C:\Program Files\Zabbix Agent 2\zabbix_agent2.psk'

function Get-TaskParam([string]$Name, $Default = $null) {
    $v = Get-Variable -Name $Name -ValueOnly -ErrorAction SilentlyContinue
    if ($null -eq $v -or ($v -is [string] -and [string]::IsNullOrWhiteSpace($v))) { return $Default }
    return $v
}
function ConvertTo-PlainText($Value) {
    if ($Value -is [securestring]) { return [Net.NetworkCredential]::new('', $Value).Password }
    return [string]$Value
}
function Invoke-Zbx([string]$Method, $Params) {
    $body = @{ jsonrpc = '2.0'; method = $Method; params = $Params; id = 1 } | ConvertTo-Json -Depth 10 -Compress
    $r = Invoke-RestMethod -Uri $ApiUrl -Method Post -ContentType 'application/json-rpc' `
           -Headers @{ Authorization = "Bearer $ApiToken" } -Body $body -TimeoutSec 30
    if ($r.error) { throw "Zabbix API $Method failed: $($r.error.message) $($r.error.data)" }
    return $r.result
}

$injected = 'Server','Hostname','HostMetadata','RefreshActiveChecks','EnablePSK','ZabbixApiUrl','ZabbixApiToken','TemplateIds','ProxyId' |
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
# HostMetadata = the client code itself (e.g. CleverpathIT, K2_Ambassadors). Letters, digits, _ and - allowed.
# Legacy Client(s)_<CODE>[-<token>] is checked first and still accepted.
$ClientCode = if     ($HostMetadata -match '^Clients?_([A-Za-z0-9]+)(?:[-_].*)?$')    { $Matches[1] }
              elseif ($HostMetadata -match '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$')        { $HostMetadata }
              else                                                                    { $null }
if (-not $ClientCode) { Write-Warning "HostMetadata '$HostMetadata' is not a client code (letters, digits, _ or -; e.g. K2_Ambassadors); hostname will not be prefixed." }

$HostnameOverride = [string](Get-TaskParam 'Hostname')
if ($HostnameOverride -match '^\s*\$env:COMPUTERNAME\s*$') { $HostnameOverride = '' }
if ($HostnameOverride -and $HostnameOverride -notmatch '^[0-9A-Za-z .\-_]{1,128}$') {
    throw "Hostname '$HostnameOverride' contains characters Zabbix rejects (allowed: letters, digits, space, . - _)"
}
$Refresh = [int](Get-TaskParam 'RefreshActiveChecks' 60)
if ($Refresh -lt 60 -or $Refresh -gt 3600) { throw "RefreshActiveChecks must be 60-3600 (got $Refresh)" }

$pskRaw    = Get-TaskParam 'EnablePSK' $false
$EnablePSK = if ($pskRaw -is [string]) { $pskRaw -match '^(true|1|yes)$' } else { [bool]$pskRaw }
if ($EnablePSK) {
    if (-not $ClientCode) { throw 'EnablePSK requires HostMetadata to be the client code (letters, digits, _ or -; e.g. K2_Ambassadors); it selects host group Clients/<CODE> (case-sensitive)' }
    $ApiUrl   = [string](Get-TaskParam 'ZabbixApiUrl' "https://$ZbxServer/api_jsonrpc.php")
    if ($ApiUrl -notmatch 'api_jsonrpc\.php$') { $ApiUrl = $ApiUrl.TrimEnd('/') + '/api_jsonrpc.php' }
    $ApiToken = ConvertTo-PlainText (Get-TaskParam 'ZabbixApiToken')
    if (-not $ApiToken) { throw 'EnablePSK requires ZabbixApiToken' }
    $TemplateIds = @(([string](Get-TaskParam 'TemplateIds')) -split '[,;\s]+' | Where-Object { $_ -match '^\d+$' })
    $ProxyId     = [string](Get-TaskParam 'ProxyId')
    $GroupName   = "Clients/$ClientCode"
}

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
    $Desired['TLSPSKIdentity'] = ''                       # = resolved Hostname
    $Desired['TLSPSKFile']     = $PSKFile
}
$DesiredKeys = [string[]]$Desired.Keys
# -------------------------------------------------------------------------

$ep = @(Invoke-ImmyCommand {
    $Desired       = $using:Desired
    $DesiredKeys   = $using:DesiredKeys
    $ManagedKeys   = $using:ManagedKeys
    $ConfigPath    = $using:ConfigPath
    $ClientCode    = $using:ClientCode
    $EnablePSK     = $using:EnablePSK
    $PSKFile       = $using:PSKFile
    $LegacyPSKFile = $using:LegacyPSKFile

    if (-not (Test-Path $ConfigPath)) {
        Write-Warning "Config not found: $ConfigPath"
        return [pscustomobject]@{ Ok = $false; Hostname = $null }
    }

    if (-not $Desired['Hostname']) {
        $Desired['Hostname'] = if ($ClientCode) { "$ClientCode-$env:COMPUTERNAME" } else { $env:COMPUTERNAME }
    }
    if ($EnablePSK) { $Desired['TLSPSKIdentity'] = $Desired['Hostname'] }

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
        $cur = if (Test-Path $PSKFile) { ([string](Get-Content $PSKFile -Raw)).Trim() } else { '' }
        if ($cur -notmatch '^[0-9a-f]{64}$') { Write-Warning 'Per-host PSK file missing or malformed'; $ok = $false }
        if (Test-Path $LegacyPSKFile) { Write-Warning "Legacy shared PSK file still present: $LegacyPSKFile"; $ok = $false }
    }

    $svc = Get-Service -Name 'Zabbix Agent 2' -ErrorAction SilentlyContinue
    if (-not $svc) { Write-Warning 'Service "Zabbix Agent 2" not found'; $ok = $false }
    elseif ($svc.Status -ne 'Running') { Write-Warning "Service is $($svc.Status)"; $ok = $false }
    elseif ($svc.StartType -ne 'Automatic') { Write-Warning "Service StartType is $($svc.StartType)"; $ok = $false }

    return [pscustomobject]@{ Ok = $ok; Hostname = $Desired['Hostname'] }
})[-1]   # last object only, in case anything else reached the output stream

if (-not $ep.Ok) { return $false }
if (-not $EnablePSK) { return $true }

# Server side: host must exist and require PSK in both directions
$zh = @(Invoke-Zbx 'host.get' @{
    filter           = @{ host = @($ep.Hostname) }
    output           = @('hostid', 'tls_connect', 'tls_accept')
    selectHostGroups = @('name')
})
if ($zh.Count -ne 1) {
    Write-Warning "Zabbix host '$($ep.Hostname)' not found or not visible to the API user"
    return $false
}
if ([int]$zh[0].tls_connect -ne 2 -or [int]$zh[0].tls_accept -ne 2) {
    Write-Warning "Zabbix host '$($ep.Hostname)': tls_connect=$($zh[0].tls_connect) tls_accept=$($zh[0].tls_accept), expected 2/2"
    return $false
}
if (@($zh[0].hostgroups.name) -notcontains $GroupName) {
    Write-Warning "Zabbix host '$($ep.Hostname)' is not in '$GroupName' (informational, not enforced)"
}
return $true
