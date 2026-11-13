#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Summarises what a dsh-superagent service did in the last day, and how much disk it is using.

.DESCRIPTION
  Reads the event journal (`<stateDir>/events.jsonl` and its rotated files) and counts what happened: Tickets created
  and ended by outcome, Tickets released when the one they waited for ended, split requests reported, and Decisions by kind.
  It also measures the directories that grow — the state, the work root, the backups and the journal — and says which of them
  passed its threshold.

  A summary is written to `<stateDir>/summaries/<date>.json` and printed. Run it from a scheduled task once a day.

.PARAMETER Hours
  How far back to look. Defaults to 24.

.PARAMETER Register
  Install (or, with -Unregister, remove) a daily task that runs this script at `-At`.

.PARAMETER At
  Time of day for the daily task, as HH:mm. Defaults to 09:00.

.EXAMPLE
  .\scripts\summary.ps1
.EXAMPLE
  .\scripts\summary.ps1 -Hours 168
.EXAMPLE
  .\scripts\summary.ps1 -Register
#>
[CmdletBinding()]
param(
  [string]$Profile = $(if ($env:DSH_SUPERAGENT_PROFILE) { $env:DSH_SUPERAGENT_PROFILE } else { 'superagent' }),
  [double]$Hours = 24,
  [switch]$Register,
  [switch]$Unregister,
  [string]$At = '09:00',
  # A directory that grows past its limit is reported as over it; the numbers are for a single machine, not a cluster.
  [int]$StateLimitMb = 2048,
  [int]$WorkLimitMb = 4096,
  [int]$BackupLimitMb = 2048
)

$ErrorActionPreference = 'Stop'
$stateDir = Join-Path $env:USERPROFILE ".dsh\state\$Profile"
$taskName = "dsh-superagent summary ($Profile)"

if ($Unregister) {
  Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
  Write-Host "summary: removed scheduled task '$taskName'"
  exit 0
}
if ($Register) {
  $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Profile {1}' -f $PSCommandPath, $Profile)
  $trigger = New-ScheduledTaskTrigger -Daily -At $At
  $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
  Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings `
    -Description "Summarises the last day of dsh-superagent and reports disk use" -Force | Out-Null
  Write-Host "summary: scheduled '$taskName' daily at $At"
  exit 0
}

if (-not (Test-Path $stateDir)) { Write-Host "summary: no state at $stateDir"; exit 1 }

# The journal and the files it rotated into, oldest first so the counts read in the order things happened.
$journal = @('events.jsonl', 'events.jsonl.3', 'events.jsonl.2', 'events.jsonl.1') |
  ForEach-Object { Join-Path $stateDir $_ } | Where-Object { Test-Path $_ }
$since = [datetimeoffset]::Now.AddHours(-$Hours)
$events = foreach ($file in $journal) {
  # The journal is UTF-8 without a BOM, which Windows PowerShell reads as ANSI unless told otherwise; a Ticket title with
  # Chinese in it would then break the JSON parse and the event would be counted as absent.
  foreach ($line in (Get-Content $file -Encoding UTF8)) {
    if (-not $line) { continue }
    try { $event = $line | ConvertFrom-Json } catch { continue }
    try { $at = [datetimeoffset]::Parse($event.at) } catch { continue }
    if ($at -ge $since) { $event }
  }
}

$of = { param($type) @($events | Where-Object { $_.type -eq $type }) }
$created = @(& $of 'ticket.created')
$ended = @(& $of 'ticket.ended')
$released = @(& $of 'ticket.released')
$groups = @(& $of 'group.ended')
$decisions = @(& $of 'decision.recorded')
$outcomes = @{}
foreach ($event in $ended) {
  $name = if ($event.data.outcome) { $event.data.outcome } else { 'unknown' }
  $outcomes[$name] = [int]$outcomes[$name] + 1
}
$kinds = @{}
foreach ($event in $decisions) {
  $name = if ($event.data.kind) { $event.data.kind } else { 'unknown' }
  $kinds[$name] = [int]$kinds[$name] + 1
}

function Get-SizeMb([string]$path) {
  if (-not (Test-Path $path)) { return 0 }
  $bytes = (Get-ChildItem $path -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
  if (-not $bytes) { return 0 }
  return [math]::Round($bytes / 1MB, 2)
}

$journalBytes = ($journal | ForEach-Object { (Get-Item $_).Length } | Measure-Object -Sum).Sum
if (-not $journalBytes) { $journalBytes = 0 }
$sizes = [ordered]@{
  state = Get-SizeMb $stateDir
  work = Get-SizeMb (Join-Path $stateDir 'work')
  backups = Get-SizeMb (Join-Path $stateDir 'backups')
  journalKb = [math]::Round($journalBytes / 1KB, 1)
}
$over = @(
  if ($sizes.state -gt $StateLimitMb) { "state $($sizes.state) MB > $StateLimitMb MB" }
  if ($sizes.work -gt $WorkLimitMb) { "work $($sizes.work) MB > $WorkLimitMb MB" }
  if ($sizes.backups -gt $BackupLimitMb) { "backups $($sizes.backups) MB > $BackupLimitMb MB" }
)

$summary = [ordered]@{
  at = [datetimeoffset]::Now.ToString('o')
  hours = $Hours
  profile = $Profile
  tickets = [ordered]@{ created = $created.Count; ended = $ended.Count; endedByOutcome = $outcomes
    released = $released.Count; groups = $groups.Count }
  decisions = $kinds
  megabytes = $sizes
  over = $over
}

$directory = Join-Path $stateDir 'summaries'
if (-not (Test-Path $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
$file = Join-Path $directory ('{0}.json' -f (Get-Date).ToString('yyyyMMdd-HHmmss'))
$summary | ConvertTo-Json -Depth 6 | Set-Content -Path $file -Encoding UTF8

$endedText = if ($outcomes.Count) { ($outcomes.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Key) $($_.Value)" }) -join ' / ' } else { 'none' }
$decisionText = if ($kinds.Count) { ($kinds.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Key) $($_.Value)" }) -join ' / ' } else { 'none' }
Write-Host "superagent summary for the last $Hours h ($Profile)"
Write-Host "  Tickets:  created $($created.Count), ended $($ended.Count) [$endedText], released $($released.Count), groups $($groups.Count)"
Write-Host "  Decisions: $decisionText"
Write-Host ("  Disk:     state {0} MB, work {1} MB, backups {2} MB, journal {3} KB" -f $sizes.state, $sizes.work, $sizes.backups, $sizes.journalKb)
Write-Host ("  Over the limit: {0}" -f $(if ($over.Count) { $over -join '; ' } else { 'nothing' }))
Write-Host "  Written to $file"
exit 0
