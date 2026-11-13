#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Keeps a dsh-superagent service running: checks it, restarts it when it is down, and records what happened.

.DESCRIPTION
  Run this from a scheduled task every few minutes. A service a person stopped stays stopped: the stop marker
  `superagent.ps1 stop` writes is respected, so the watchdog never fights an operator.

  Every run appends one line to `state/<profile>/watchdog.log`, so a week of running can be read back afterwards.

  Exit codes: 0 the service is up, or was restarted and came back; 1 it is still down after a restart.

.EXAMPLE
  .\scripts\watchdog.ps1
.EXAMPLE
  .\scripts\watchdog.ps1 -Profile acme -Url http://127.0.0.1:3083
#>
[CmdletBinding()]
param(
  [string]$Profile = $(if ($env:DSH_SUPERAGENT_PROFILE) { $env:DSH_SUPERAGENT_PROFILE } else { 'superagent' }),
  [string]$Url = $(if ($env:DSH_SUPERAGENT_URL) { $env:DSH_SUPERAGENT_URL } else { 'http://127.0.0.1:3082' }),
  [double]$Timeout = 90,
  # Install (or remove) the scheduled task that runs this script every `-EveryMinutes`.
  [switch]$Register,
  [switch]$Unregister,
  [int]$EveryMinutes = 5
)

$ErrorActionPreference = 'Stop'
$service = Join-Path $PSScriptRoot 'superagent.ps1'
$stateDir = Join-Path $env:USERPROFILE ".dsh\state\$Profile"
$log = Join-Path $stateDir 'watchdog.log'
$taskName = "dsh-superagent watchdog ($Profile)"
if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }

if ($Unregister) {
  Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
  Write-Host "watchdog: removed scheduled task '$taskName'"
  exit 0
}
if ($Register) {
  $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Profile {1} -Url {2}' -f $PSCommandPath, $Profile, $Url)
  $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $EveryMinutes) `
    -RepetitionDuration (New-TimeSpan -Days 3650)
  $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
  Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings `
    -Description "Restarts the dsh-superagent service when it stops, and logs each run to $log" -Force | Out-Null
  Write-Host "watchdog: scheduled '$taskName' every $EveryMinutes minutes; log at $log"
  exit 0
}

function Write-Log([string]$outcome, [string]$detail) {
  $line = '{0} {1,-9} {2}' -f (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz'), $outcome, $detail
  Add-Content -Path $log -Value $line -Encoding UTF8
  Write-Host "watchdog: $line"
}

try {
  # A person who stopped the service meant it: the marker `superagent.ps1 stop` writes is the whole answer.
  if (Test-Path (Join-Path $stateDir 'stopped-by-person')) { Write-Log 'stopped-by-person' 'not restarting'; exit 0 }

  & $service status -Profile $Profile -Url $Url *> $null
  $status = $LASTEXITCODE
  if ($status -eq 0) { Write-Log 'ok' 'running'; exit 0 }

  # 3 means it is running but waiting for setup, and 2 that a component reports an error: a restart fixes neither.
  if ($status -eq 2 -or $status -eq 3) {
    Write-Log 'needs-person' "status $status; a restart does not fix this"
    exit 0
  }

  Write-Log 'restarting' "status $status"
  & $service start -Profile $Profile -Url $Url -Timeout $Timeout -RespectStop *> $null
  $started = $LASTEXITCODE
  if ($started -ne 0) { Write-Log 'failed' "start exited $started; see host.err.log"; exit 1 }

  & $service status -Profile $Profile -Url $Url *> $null
  if ($LASTEXITCODE -eq 0) { Write-Log 'recovered' 'restarted and answering'; exit 0 }
  Write-Log 'failed' "restarted but status is $LASTEXITCODE"; exit 1
} catch {
  Write-Log 'failed' $_.Exception.Message
  exit 1
}
