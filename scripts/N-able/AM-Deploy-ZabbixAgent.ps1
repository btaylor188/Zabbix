<#
  N-able Automation Manager — body of the "Run PowerShell Script" object in policy "Zabbix Agent - Deploy".

  Object INPUT parameters (String; bind to the policy input of the same name):
    ClientCode
  Everything else is a constant below. No Zabbix proxy support.
  Agent version is pinned: installs if missing, upgrades if older, never downgrades.
  To roll a new version: change $AgentVersion + $MsiSha256, save the .amp, re-upload.
  !! Contains the API token once filled in. Never commit the filled-in script or the .amp to git. !!
  Host group is resolved as Clients/<ClientCode> via hostgroup.get (group must pre-exist).
  API role needs: host.get, host.create, host.update, hostgroup.get.
  Object OUTPUT parameters (String):
    ZbxStatus  = OK | FAIL
    ZbxMessage = one-line summary (never contains the PSK or token)

  No param() block and no exit: AM injects the inputs as variables and reads the outputs back.
  The policy branches on ZbxStatus to fail (see build notes).
  Works whether AM runs it as 32-bit or 64-bit, and does not depend on environment variables
  (N-sight's script runner may start PowerShell without them): paths come from the registry/.NET APIs.
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$ZbxStatus  = 'FAIL'
$ZbxMessage = 'not run'

$ZabbixApiUrl   = 'https://monitoring.example.com/api_jsonrpc.php'
$ZabbixApiToken = 'REPLACE_WITH_API_TOKEN'        # single shared token; rotate before expiry
$ServerActive   = 'monitoring.example.com'   # agent -> server trapper, TCP 10051
$PassiveServer  = '127.0.0.1'                     # Server= (passive checks). Active-only design: localhost only. MSI requires a value.
$TemplateIds    = '10685'                         # comma-separated if more than one
$AgentVersion   = 'REPLACE_X.Y.Z'                 # e.g. 7.4.5 — keep <= server version
$MsiSha256      = 'REPLACE_WITH_MSI_SHA256'       # SHA256 of the exact MSI below
$MsiUrl         = $null                           # derived below from $AgentVersion (cdn.zabbix.com); override to self-host
$SvcName        = 'Zabbix Agent 2'

if ($AgentVersion -match '^(\d+)\.(\d+)\.\d+$' -and -not $MsiUrl) {
  $MsiUrl = 'https://cdn.zabbix.com/zabbix/binaries/stable/{0}.{1}/{2}/zabbix_agent2-{2}-windows-amd64-openssl.msi' -f $Matches[1], $Matches[2], $AgentVersion
}

# Installed Agent 2 version from the 64-bit uninstall key (works from 32-bit hosts too); $null if absent
function Get-InstalledAgentVersion {
  $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry64')
  $un   = $base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
  foreach ($n in $un.GetSubKeyNames()) {
    $k = $un.OpenSubKey($n)
    if ($k -and ($k.GetValue('DisplayName') -like 'Zabbix Agent 2*')) {
      $v = $null
      if ([version]::TryParse([string]$k.GetValue('DisplayVersion'), [ref]$v)) {
        return [version]('{0}.{1}.{2}' -f $v.Major, $v.Minor, [Math]::Max($v.Build, 0))
      }
    }
  }
  $null
}
# System paths without relying on environment variables
function Get-SysPaths {
  $pf = $null
  try { $pf = [string][Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry64').OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion').GetValue('ProgramFilesDir') } catch { }
  if (-not $pf) { $pf = $env:ProgramW6432 }
  if (-not $pf) { $pf = $env:ProgramFiles }
  if (-not $pf) { $pf = 'C:\Program Files' }
  $win = [Environment]::GetFolderPath('Windows')
  if (-not $win) { $win = $env:SystemRoot }
  if (-not $win) { $win = 'C:\Windows' }
  [pscustomobject]@{ ProgramFiles = $pf; Windows = $win; System32 = [IO.Path]::Combine($win, 'System32') }
}

# $AgentDir/$Conf/$PskFile are set inside Invoke-ZabbixDeploy (helpers see them via scope) so any failure lands in ZbxMessage

function Invoke-Zbx([string]$Method, $Params) {
  $body = @{ jsonrpc = '2.0'; method = $Method; params = $Params; id = 1 } | ConvertTo-Json -Depth 10 -Compress
  $r = Invoke-RestMethod -Uri $ZabbixApiUrl -Method Post -ContentType 'application/json-rpc' `
         -Headers @{ Authorization = "Bearer $ZabbixApiToken" } -Body $body -TimeoutSec 30
  if ($r.error) { throw "API $Method failed: $($r.error.message) $($r.error.data)" }
  $r.result
}

function Set-ConfLine([string[]]$Lines, [string]$Key, [string]$Value) {
  $pat  = '^\s*#?\s*' + [regex]::Escape($Key) + '\s*='
  $out  = New-Object System.Collections.Generic.List[string]
  $done = $false
  foreach ($l in $Lines) {
    if ($l -match $pat) { if (-not $done) { $out.Add("$Key=$Value"); $done = $true } }
    else { $out.Add($l) }
  }
  if (-not $done) { $out.Add("$Key=$Value") }
  ,$out.ToArray()
}

function Get-DesiredConf([string]$HostName) {
  if (-not (Test-Path $Conf)) { return $null }
  $orig = [IO.File]::ReadAllLines($Conf)
  $new  = $orig
  $want = [ordered]@{
    Server         = $PassiveServer
    ServerActive   = $ServerActive
    Hostname       = $HostName
    HostMetadata   = $ClientCode
    TLSConnect     = 'psk'
    TLSAccept      = 'psk'
    TLSPSKIdentity = $HostName
    TLSPSKFile     = $PskFile
  }
  foreach ($k in $want.Keys) { $new = Set-ConfLine $new $k $want[$k] }
  [pscustomobject]@{ Lines = $new; Changed = (($orig -join "`n") -ne ($new -join "`n")) }
}

function Invoke-ZabbixDeploy {
  $Sys      = Get-SysPaths
  $PF       = $Sys.ProgramFiles
  $Icacls   = Join-Path $Sys.System32 'icacls.exe'
  $Msiexec  = Join-Path $Sys.System32 'msiexec.exe'
  $AgentDir = Join-Path $PF 'Zabbix Agent 2'
  $Conf     = Join-Path $AgentDir 'zabbix_agent2.conf'
  $PskFile  = Join-Path $AgentDir 'zabbix_agent2.psk'

  if ($ZabbixApiToken -notmatch '^[0-9a-fA-F]{64}$') { throw 'ZabbixApiToken not set in script (placeholder or malformed)' }
  if ($AgentVersion -notmatch '^\d+\.\d+\.\d+$') { throw 'AgentVersion not set in script (placeholder or malformed)' }
  if ($MsiSha256 -notmatch '^[0-9a-fA-F]{64}$')  { throw 'MsiSha256 not set in script (placeholder or malformed)' }
  if ([string]::IsNullOrWhiteSpace([string](Get-Variable -Name ClientCode -ValueOnly -ErrorAction SilentlyContinue))) { throw 'missing input ClientCode' }
  $target = [version]$AgentVersion
  if ($ClientCode -notmatch '^[A-Za-z0-9_-]+$') { throw 'ClientCode must match [A-Za-z0-9_-]+' }
  $HostName = "$ClientCode-$([Environment]::MachineName)"
  $Identity = $HostName

  # 1. Per-host PSK: reuse if valid, else generate 256-bit
  New-Item -ItemType Directory -Path $AgentDir -Force | Out-Null
  $Psk = $null
  if (Test-Path $PskFile) { $raw = [IO.File]::ReadAllText($PskFile); if ($raw) { $Psk = $raw.Trim() } }
  $newPsk = $Psk -notmatch '^[0-9a-fA-F]{64}$'
  if ($newPsk) {
    $b = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
    $Psk = -join ($b | ForEach-Object { $_.ToString('x2') })
    [IO.File]::WriteAllText($PskFile, $Psk)
  }
  & $Icacls $PskFile /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "icacls exit $LASTEXITCODE on PSK file" }

  # 2. Fast path: compliant and connected -> no API writes
  $svc       = Get-Service -Name $SvcName -ErrorAction SilentlyContinue
  $installedVer = Get-InstalledAgentVersion
  $needAgent = (-not $svc) -or (-not $installedVer) -or ($installedVer -lt $target)
  $conf      = Get-DesiredConf $HostName
  $hostRec   = @(Invoke-Zbx 'host.get' @{
    output = @('hostid','tls_connect','tls_accept','active_available')
    filter = @{ host = @($HostName) }
  })
  if (-not $newPsk -and -not $needAgent -and $svc.Status -eq 'Running' -and $conf -and -not $conf.Changed -and
      $hostRec.Count -eq 1 -and $hostRec[0].tls_connect -eq '2' -and $hostRec[0].tls_accept -eq '2' -and
      $hostRec[0].active_available -eq '1') {
    return "$HostName compliant, no changes"
  }

  # 3. Register/update host; tls_accept=3 (unencrypted+PSK) during cutover
  $tls      = @{ tls_connect = 2; tls_accept = 3; tls_psk_identity = $Identity; tls_psk = $Psk }

  if ($hostRec.Count -eq 1) {
    $hostId = $hostRec[0].hostid
    # groups/templates deliberately not sent on update (host.update replaces them)
    Invoke-Zbx 'host.update' (@{ hostid = $hostId } + $tls) | Out-Null
    $action = 'updated'
  } else {
    # Resolve Clients/<ClientCode> (case-insensitive; search is substring, so filter to exact name)
    $groupName = "Clients/$ClientCode"
    $grp = @(Invoke-Zbx 'hostgroup.get' @{ output = @('groupid','name'); search = @{ name = $groupName } } |
             Where-Object { $_.name -ieq $groupName })
    if ($grp.Count -eq 0) { throw "host group '$groupName' not found (create it, and grant the API user RW)" }
    if ($grp.Count -gt 1) { throw "multiple host groups match '$groupName' (case-only duplicates)" }

    $tpl = @($TemplateIds -split ',' | Where-Object { $_.Trim() } | ForEach-Object { @{ templateid = $_.Trim() } })
    $res = Invoke-Zbx 'host.create' (@{
      host      = $HostName
      groups    = @(@{ groupid = $grp[0].groupid })
      templates = $tpl
    } + $tls)
    $hostId = $res.hostids[0]
    $action = 'created'
  }

  # 4. Install if missing, upgrade if older than $AgentVersion (PSK passed by file path, never on the command line)
  #    MSI properties re-assert the TLS settings; step 5 re-enforces the conf regardless of what the upgrade did to it
  $installed = $false
  if ($needAgent) {
    $msi = Join-Path $Sys.Windows 'Temp\zabbix_agent2.msi'
    Invoke-WebRequest -Uri $MsiUrl -OutFile $msi -UseBasicParsing
    if ((Get-FileHash -Path $msi -Algorithm SHA256).Hash -ne $MsiSha256.Trim().ToUpper()) {
      Remove-Item $msi -Force
      throw 'MSI SHA256 mismatch'
    }
    # SERVER is mandatory for the MSI (LaunchConditions fails with 1603 without it)
    $msiArgs = ('/i "{0}" /qn /norestart /l*v "{0}.log" SERVER="{5}" SERVERACTIVE="{1}" HOSTNAME="{2}" ' +
                'TLSCONNECT=psk TLSACCEPT=psk TLSPSKIDENTITY="{3}" TLSPSKFILE="{4}"') -f $msi, $ServerActive, $HostName, $Identity, $PskFile, $PassiveServer
    # Stop the running agent first so an upgrade doesn't defer file replacement to a reboot
    if ($svc -and $svc.Status -ne 'Stopped') { Stop-Service -Name $SvcName -Force }
    $p = Start-Process -FilePath $Msiexec -ArgumentList $msiArgs -Wait -PassThru
    if ($p.ExitCode -notin 0, 3010) {
      # Don't leave a previously working agent stopped
      if ($svc) { Start-Service -Name $SvcName -ErrorAction SilentlyContinue }
      throw "msiexec exit $($p.ExitCode) (log: $msi.log)"
    }
    Remove-Item $msi -Force -ErrorAction SilentlyContinue
    # Belt and braces: the PSK file isn't MSI-owned, but restore it if an upgrade removed it
    if (-not (Test-Path $PskFile)) {
      [IO.File]::WriteAllText($PskFile, $Psk)
      & $Icacls $PskFile /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' | Out-Null
    }
    $installed = $true
    $conf = Get-DesiredConf $HostName
  }
  if (-not $conf) { throw "config not found: $Conf" }

  # 5. Enforce config; restart only if something changed
  if ($conf.Changed) { [IO.File]::WriteAllLines($Conf, $conf.Lines) }   # UTF-8, no BOM
  Set-Service -Name $SvcName -StartupType Automatic
  if ($conf.Changed -or $newPsk -or $installed) { Restart-Service -Name $SvcName -Force }
  elseif ((Get-Service -Name $SvcName).Status -ne 'Running') { Start-Service -Name $SvcName }
  (Get-Service -Name $SvcName).WaitForStatus('Running', [TimeSpan]::FromSeconds(30))

  # 6. Tighten to PSK-only
  Invoke-Zbx 'host.update' @{ hostid = $hostId; tls_accept = 2 } | Out-Null

  $pskState   = if ($newPsk) { 'generated' } else { 'reused' }
  $agentState = if (-not $installed) { "present $installedVer" }
                elseif ($installedVer) { "upgraded $installedVer -> $AgentVersion" }
                else { "installed $AgentVersion" }
  return "$HostName $action; PSK $pskState; agent $agentState"
}

try {
  # [-1] guards against stray pipeline output ahead of the return value
  $ZbxMessage = [string]@(Invoke-ZabbixDeploy)[-1]
  $ZbxStatus  = 'OK'
} catch {
  $ZbxStatus  = 'FAIL'
  $ZbxMessage = '{0} (line {1})' -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber
}
