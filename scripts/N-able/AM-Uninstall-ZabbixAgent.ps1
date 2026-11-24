<#
  N-able Automation Manager — body of the "Run PowerShell Script" object in policy "Zabbix Agent - Uninstall".
  Removes Zabbix Agent 2 and its PSK. Does NOT delete the Zabbix host (API user has no host.delete).

  Object INPUT parameters:  none
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

function Invoke-ZabbixUninstall {
  # Read the 64-bit uninstall view explicitly; AM may host PowerShell as 32-bit
  $base  = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry64')
  $un    = $base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
  $codes = @(foreach ($n in $un.GetSubKeyNames()) {
    $k = $un.OpenSubKey($n)
    if ($k -and ($k.GetValue('DisplayName') -like 'Zabbix Agent 2*') -and $n -match '^\{[0-9A-Fa-f-]+\}$') { $n }
  })

  foreach ($c in $codes) {
    $p = Start-Process -FilePath ([IO.Path]::Combine([Environment]::GetFolderPath('Windows'), 'System32', 'msiexec.exe')) -ArgumentList "/x $c /qn /norestart" -Wait -PassThru
    if ($p.ExitCode -notin 0, 3010, 1605) { throw "msiexec /x $c exit $($p.ExitCode)" }
  }

  $PF = Get-ProgramFiles64
  Remove-Item -Path (Join-Path $PF 'Zabbix Agent 2') -Recurse -Force -ErrorAction SilentlyContinue
  return "removed $($codes.Count) product(s)"
}

try {
  $ZbxMessage = [string]@(Invoke-ZabbixUninstall)[-1]
  $ZbxStatus  = 'OK'
} catch {
  $ZbxStatus  = 'FAIL'
  $ZbxMessage = '{0} (line {1})' -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber
}
