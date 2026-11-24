<#
  ImmyBot Software: "Custom Zabbix" — UNINSTALL script
  Execution context: System (runs on the endpoint; no Invoke-ImmyCommand).

  1. Finds installed Zabbix Agent 2 products by MSI UpgradeCode (fallback: Uninstall registry keys).
  2. Stops the service, runs msiexec /x for each product code.
  3. Purges what the MSI does not own: the managed conf, the PSK file, *.immybak backups (these hold the
     HostMetadata token and the PSK), logs, and the install folder. Deletes an orphaned service and any
     firewall rules that point at the agent binary.
  4. Verifies nothing is left, and throws if something is.

  Exit codes accepted from msiexec: 0, 1605 (already gone), 3010/1641 (reboot required; reported, not failed).
  Remember to delete or disable the host in Zabbix, or its nodata triggers will fire.
#>

$UpgradeCode = '{3B47322E-1899-47A6-BD5D-D06FA0AC0EDD}'
$ServiceName = 'Zabbix Agent 2'
$InstallDir  = 'C:\Program Files\Zabbix Agent 2'
$LogDir      = Join-Path $env:SystemRoot 'Temp'

function Get-ZabbixProductCodes {
    $codes = @()
    try {
        $msi = New-Object -ComObject WindowsInstaller.Installer
        $related = $msi.GetType().InvokeMember('RelatedProducts', 'GetProperty', $null, $msi, @($UpgradeCode))
        foreach ($c in $related) { $codes += [string]$c }
    } catch {
        Write-Warning "WindowsInstaller COM lookup failed: $($_.Exception.Message)"
    }
    if (-not $codes) {
        # Fallback: MSI-based uninstall entries for the agent
        $roots = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
        foreach ($r in $roots) {
            Get-ChildItem $r -ErrorAction SilentlyContinue | ForEach-Object {
                $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
                if ($p.DisplayName -like 'Zabbix Agent 2*' -and $_.PSChildName -match '^\{[0-9A-Fa-f-]{36}\}$') {
                    $codes += $_.PSChildName
                }
            }
        }
    }
    return @($codes | Select-Object -Unique)
}

$rebootRequired = $false
$codes = Get-ZabbixProductCodes
Write-Host "Zabbix Agent 2 product codes found: $(if ($codes) { $codes -join ', ' } else { '(none)' })"

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -ne 'Stopped') {
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    try { $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30)) } catch { Write-Warning "Service did not stop within 30s" }
}

foreach ($code in $codes) {
    $log  = Join-Path $LogDir ("zabbix_agent2_uninstall_{0}.log" -f ($code -replace '[{}]', ''))
    $msiArgs = "/x $code /qn /norestart /l*v `"$log`""
    Write-Host "msiexec $msiArgs"
    $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru
    switch ($p.ExitCode) {
        0       { Write-Host "Uninstalled $code" }
        1605    { Write-Host "$code not installed (1605)" }
        3010    { Write-Host "Uninstalled $code, reboot required (3010)"; $rebootRequired = $true }
        1641    { Write-Host "Uninstalled $code, reboot initiated by installer (1641)"; $rebootRequired = $true }
        default { throw "msiexec /x $code failed with exit code $($p.ExitCode). Log: $log" }
    }
}

# Orphaned service (e.g. a manual non-MSI install, or an MSI that left it behind)
if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    & sc.exe delete "$ServiceName" | Out-Null
    Write-Host "Deleted leftover service '$ServiceName' (sc.exe exit $LASTEXITCODE)"
}

# Firewall rules that point at the agent binary
try {
    Get-NetFirewallApplicationFilter -ErrorAction Stop |
        Where-Object { $_.Program -like "$InstallDir\*" } |
        Get-NetFirewallRule -ErrorAction SilentlyContinue |
        ForEach-Object { Write-Host "Removing firewall rule '$($_.DisplayName)'"; $_ | Remove-NetFirewallRule }
} catch {
    Write-Warning "Firewall rule cleanup skipped: $($_.Exception.Message)"
}

# Purge leftovers. The conf, PSK and backups contain the client token/PSK; they must not survive.
if (Test-Path $InstallDir) {
    Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path $InstallDir) {
        # Something held a file open; retry once after a short wait
        Start-Sleep -Seconds 5
        Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Verify
$problems = @()
if (Get-ZabbixProductCodes)                                   { $problems += 'MSI product still registered' }
if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) { $problems += 'service still present' }
if (Test-Path $InstallDir)                                   { $problems += "$InstallDir still exists" }

if ($problems) {
    if ($rebootRequired -and $problems.Count -eq 1 -and $problems[0] -like '*still exists') {
        Write-Warning "Uninstall complete; $InstallDir will need removal after the pending reboot."
    } else {
        throw "Zabbix Agent 2 uninstall incomplete: $($problems -join '; ')"
    }
}
Write-Host "Zabbix Agent 2 removed.$(if ($rebootRequired) { ' Reboot required to finish.' })"
