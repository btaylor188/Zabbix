<#
  ImmyBot Configuration Task: "Custom Zabbix Deployment" - SET script (separate-script mode)

  No param() block on purpose; see the Test script header. The resolve block below must
  stay identical to the one in the Test script.

  Flow when EnablePSK:
    0. Metascript : resolve Clients/<CODE> host group (fail fast, nothing touched yet)
    1. Endpoint   : resolve Hostname; ensure per-host PSK file (reuse if valid, else generate 256-bit); ACL it
    2. Metascript : host.update / host.create with PSK; tls_accept=3 (unencrypted+PSK) for a gapless cutover
    3. Endpoint   : back up conf, write managed block, validate with -T, restart; restore backup on failure
    4. Metascript : tighten tls_accept=2 (PSK only). On step-3 failure, revert tls_accept to its prior value.
  Legacy shared zabbix_agent2.psk (and its .immybak) are deleted after a successful step 3.
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

# ---- 0. Resolve host group before touching anything ----
if ($EnablePSK) {
    $grp = @(Invoke-Zbx 'hostgroup.get' @{ filter = @{ name = @($GroupName) }; output = @('groupid') })
    if ($grp.Count -ne 1) {
        throw "Host group '$GroupName' not found or not visible to the API user. Create it under Data collection > Host groups (parent 'Clients' must exist)."
    }
    $GroupId = $grp[0].groupid
}

# ---- 1. Endpoint: resolve Hostname, ensure per-host PSK ----
$prep = @(Invoke-ImmyCommand {
    $HostnameOverride = $using:HostnameOverride
    $ClientCode       = $using:ClientCode
    $ConfigPath       = $using:ConfigPath
    $EnablePSK        = $using:EnablePSK
    $PSKFile          = $using:PSKFile

    if (-not (Test-Path $ConfigPath)) { throw "Zabbix config not found at $ConfigPath (is the agent installed?)" }

    $hn = if ($HostnameOverride) { $HostnameOverride }
          elseif ($ClientCode)   { "$ClientCode-$env:COMPUTERNAME" }
          else                   { $env:COMPUTERNAME }

    $key = $null
    if ($EnablePSK) {
        $key = if (Test-Path $PSKFile) { ([string](Get-Content $PSKFile -Raw)).Trim() } else { '' }
        if ($key -notmatch '^[0-9a-f]{64}$') {
            $b = New-Object byte[] 32
            [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
            $key = -join ($b | ForEach-Object { $_.ToString('x2') })
            [IO.File]::WriteAllText($PSKFile, $key)   # no trailing newline, no BOM
        }
        & icacls.exe $PSKFile /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "icacls failed on $PSKFile (exit $LASTEXITCODE)" }
    }
    [pscustomobject]@{ Hostname = $hn; PSK = $key }
})[-1]   # last object only, in case anything else reached the output stream

$ZbxHost = $prep.Hostname
$Desired['Hostname'] = $ZbxHost
if ($EnablePSK) {
    $Desired['TLSPSKIdentity'] = $ZbxHost
    if ($prep.PSK -notmatch '^[0-9a-f]{64}$') { throw 'PSK missing or malformed after endpoint preparation' }
}

# ---- 2. Server side: set PSK, accept unencrypted+PSK during cutover ----
$ZbxHostId  = $null
$PrevAccept = $null
if ($EnablePSK) {
    $tls = @{ tls_connect = 2; tls_accept = 3; tls_psk_identity = $ZbxHost; tls_psk = $prep.PSK }
    $zh  = @(Invoke-Zbx 'host.get' @{ filter = @{ host = @($ZbxHost) }; output = @('hostid', 'tls_accept') })
    if ($zh.Count -eq 1) {
        $ZbxHostId  = $zh[0].hostid
        $PrevAccept = [int]$zh[0].tls_accept
        Invoke-Zbx 'host.update' (@{ hostid = $ZbxHostId } + $tls) | Out-Null
        Write-Host "Zabbix host '$ZbxHost' updated with per-host PSK (cutover mode)"
    } else {
        if (-not $TemplateIds) { throw "Zabbix host '$ZbxHost' does not exist and TemplateIds is empty; refusing to create an unmonitored host" }
        $p = @{
            host      = $ZbxHost
            groups    = @(@{ groupid = $GroupId })
            templates = @($TemplateIds | ForEach-Object { @{ templateid = $_ } })
        } + $tls
        if ($ProxyId) { $p.monitored_by = 1; $p.proxyid = $ProxyId }
        try {
            $ZbxHostId = (Invoke-Zbx 'host.create' $p).hostids[0]
        } catch {
            if ("$_" -match 'already exists') {
                throw "Zabbix host '$ZbxHost' exists but is not visible to the API user. Move it into '$GroupName' or grant the API user group access to its current group."
            }
            throw
        }
        Write-Host "Zabbix host '$ZbxHost' created in '$GroupName' (cutover mode)"
    }
}

# ---- 3. Endpoint: write config, validate, restart ----
try {
    Invoke-ImmyCommand {
        $Desired       = $using:Desired
        $DesiredKeys   = $using:DesiredKeys
        $ManagedKeys   = $using:ManagedKeys
        $ConfigPath    = $using:ConfigPath
        $EnablePSK     = $using:EnablePSK
        $LegacyPSKFile = $using:LegacyPSKFile

        $ServiceName = 'Zabbix Agent 2'
        $AgentDir    = Split-Path $ConfigPath -Parent
        $AgentExe    = Join-Path $AgentDir 'zabbix_agent2.exe'
        $Backup      = "$ConfigPath.immybak"
        $Marker      = '# --- ImmyBot managed parameters (do not edit by hand) ---'

        if (-not (Test-Path $ConfigPath)) { throw "Zabbix config not found at $ConfigPath (is the agent installed?)" }
        if (-not (Test-Path $AgentExe))   { throw "Agent binary not found at $AgentExe" }

        Copy-Item $ConfigPath $Backup -Force
        function Restore-Backup([switch]$Restart) {
            Copy-Item $Backup $ConfigPath -Force
            if ($Restart) { Restart-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue }
        }

        $kept = @(Get-Content $ConfigPath | Where-Object {
            if ($_ -eq $Marker) { return $false }
            if ($_ -match '^\s*#' -or $_ -notmatch '=') { return $true }
            $key = ($_ -split '\s*=\s*', 2)[0].Trim()
            return -not ($ManagedKeys -contains $key)
        })
        $last = $kept.Count - 1
        while ($last -ge 0 -and [string]::IsNullOrWhiteSpace($kept[$last])) { $last-- }
        $kept = if ($last -ge 0) { $kept[0..$last] } else { @() }

        $block = @('', $Marker)
        foreach ($key in $DesiredKeys) { $block += "$key=$($Desired[$key])" }

        [IO.File]::WriteAllLines($ConfigPath, [string[]]($kept + $block))   # UTF-8 without BOM

        Push-Location $AgentDir
        $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
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

        if ($EnablePSK) {
            # Old shared key and the old script's backup copy of it
            Remove-Item $LegacyPSKFile, "$LegacyPSKFile.immybak" -Force -ErrorAction SilentlyContinue
        }

        Write-Host "Zabbix Agent 2 configured: Hostname=$($Desired['Hostname']) ServerActive=$($Desired['ServerActive']) PSK=$EnablePSK"
    }
} catch {
    if ($EnablePSK -and $null -ne $PrevAccept) {
        try {
            Invoke-Zbx 'host.update' @{ hostid = $ZbxHostId; tls_accept = $PrevAccept } | Out-Null
            Write-Warning "Endpoint config failed; reverted Zabbix tls_accept to $PrevAccept"
        } catch {
            Write-Warning "Endpoint config failed AND reverting tls_accept failed: $_"
        }
    }
    throw
}

# ---- 4. Tighten: PSK only ----
if ($EnablePSK) {
    Invoke-Zbx 'host.update' @{ hostid = $ZbxHostId; tls_accept = 2 } | Out-Null
    Write-Host "Zabbix host '$ZbxHost' set to PSK-only"
}
