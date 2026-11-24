<#
  N-able Automation Manager — body of the "Run PowerShell Script" object in policy "Zabbix Agent - Check".
  Local compliance only; no API calls, no secrets.

  Object INPUT parameters:  ClientCode (String)
  Object OUTPUT parameters: ZbxStatus (OK | FAIL), ZbxMessage (String)
#>

$ErrorActionPreference = 'Stop'
$ZbxStatus  = 'FAIL'
$ZbxMessage = 'not run'

# Program Files (64-bit) without relying on environment variables (N-sight's runner may not provide them)
function Get-ProgramFiles64 {
  $pf = $null
  try { $pf = [string][Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry64').OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion').GetValue('ProgramFilesDir') } catch { }
  if (-not $pf) { $pf = $env:ProgramW6432 }
  if (-not $pf) { $pf = $env:ProgramFiles }
  if (-not $pf) { $pf = 'C:\Program Files' }
  $pf
}

function Invoke-ZabbixCheck {
  if ([string]::IsNullOrWhiteSpace([string](Get-Variable -Name ClientCode -ValueOnly -ErrorAction SilentlyContinue))) { throw 'missing input ClientCode' }

  $PF       = Get-ProgramFiles64
  $AgentDir = Join-Path $PF 'Zabbix Agent 2'
  $Conf     = Join-Path $AgentDir 'zabbix_agent2.conf'
  $PskFile  = Join-Path $AgentDir 'zabbix_agent2.psk'
  $LogFile  = Join-Path $AgentDir 'zabbix_agent2.log'
  $SvcName  = 'Zabbix Agent 2'
  $HostName = "$ClientCode-$([Environment]::MachineName)"

  $issues = New-Object System.Collections.Generic.List[string]

  $svc = Get-Service -Name $SvcName -ErrorAction SilentlyContinue
  if (-not $svc) { $issues.Add('agent not installed') }
  elseif ($svc.Status -ne 'Running') { $issues.Add("service $($svc.Status)") }

  if (-not (Test-Path $PskFile) -or ([IO.File]::ReadAllText($PskFile).Trim() -notmatch '^[0-9a-fA-F]{64}$')) {
    $issues.Add('PSK file missing/invalid')
  }

  if (Test-Path $Conf) {
    $active = @{}
    foreach ($l in [IO.File]::ReadAllLines($Conf)) {
      if ($l -match '^\s*([A-Za-z]+)\s*=\s*(.*?)\s*$') { $active[$Matches[1]] = $Matches[2] }
    }
    $want = @{ Hostname = $HostName; TLSConnect = 'psk'; TLSAccept = 'psk'; TLSPSKIdentity = $HostName; TLSPSKFile = $PskFile }
    foreach ($k in $want.Keys) { if ($active[$k] -ne $want[$k]) { $issues.Add("$k mismatch") } }
  } else { $issues.Add('config missing') }

  # Last active-check state transition in the agent log (best effort; message text unverified across versions)
  if (Test-Path $LogFile) {
    $last = Get-Content -Path $LogFile -Tail 500 | Select-String -Pattern 'started to fail|is working again' | Select-Object -Last 1
    if ($last -and $last.Line -match 'started to fail') { $issues.Add('active checks failing (see agent log)') }
  }

  if ($issues.Count) { throw ($issues -join '; ') }
  return "$HostName OK"
}

try {
  $ZbxMessage = [string]@(Invoke-ZabbixCheck)[-1]
  $ZbxStatus  = 'OK'
} catch {
  $ZbxStatus  = 'FAIL'
  $ZbxMessage = '{0} (line {1})' -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber
}
