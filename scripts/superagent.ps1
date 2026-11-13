#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Manage a local dsh-superagent service (one DSH profile, default `superagent`) on Windows.

.DESCRIPTION
  The Windows counterpart of `scripts/dsh-superagent`. Same verbs, same exit codes, no tmux:

    status, start, restart exit 0 while the service runs normally;
    1 when it is stopped, duplicated, unreachable, or reporting a runtime error, which `restart` may fix;
    2 when it runs while a component such as a Source reports an error;
    3 when it runs and waits for setup.
    A restart fixes neither 2 nor 3: they need a person.

.PARAMETER Action
  start | stop | restart | status | url | backup | restore

.PARAMETER Backup
  For `restore`: the file to restore from. Defaults to the newest one in `backups`.

.PARAMETER Keep
  For `backup`: how many daily files to keep before the oldest is removed. Defaults to 14.

.PARAMETER Profile
  DSH profile name. Defaults to $env:DSH_SUPERAGENT_PROFILE, then `superagent`.

.PARAMETER Url
  Management API base. Defaults to $env:DSH_SUPERAGENT_URL, then http://127.0.0.1:3082.

.EXAMPLE
  .\scripts\superagent.ps1 start
.EXAMPLE
  .\scripts\superagent.ps1 status; $LASTEXITCODE
.EXAMPLE
  .\scripts\superagent.ps1 restart -Profile acme -Url http://127.0.0.1:3083
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('start', 'stop', 'restart', 'status', 'url', 'backup', 'restore')]
  [string]$Action = 'status',

  [string]$Backup = '',
  [int]$Keep = 14,

  [string]$Profile = $(if ($env:DSH_SUPERAGENT_PROFILE) { $env:DSH_SUPERAGENT_PROFILE } else { 'superagent' }),
  [string]$Url = $(if ($env:DSH_SUPERAGENT_URL) { $env:DSH_SUPERAGENT_URL } else { 'http://127.0.0.1:3082' }),
  [double]$Timeout = 60,
  [double]$StopTimeout = 300,
  # Leave a service that a person stopped stopped instead of starting it again.
  [switch]$RespectStop
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$home_ = $env:USERPROFILE
$profileDir = Join-Path $home_ ".dsh\profiles\$Profile"
$stateDir = Join-Path $home_ ".dsh\state\$Profile"
$outLog = Join-Path $stateDir 'host.out.log'
$errLog = Join-Path $stateDir 'host.err.log'
$pidFile = Join-Path $stateDir 'host.pid'
$stopMarker = Join-Path $stateDir 'stopped-by-person'
$lockFile = "$stateDir.lock"

$exe = Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\DeepSeek Harness.exe'
# Paths inside app.asar are only readable to Electron, so the archive itself is what can be checked from here.
$asarFile = Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\resources\app.asar'
$asarRoot = Join-Path $asarFile 'dsh'
$hostJs = Join-Path $asarRoot 'node_modules\@deepseek-ai\dsh-desktop-host\lib\index.js'
$runtimeRoot = Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\resources\runtime\primary-runtime'
$pnpmJs = Join-Path $runtimeRoot 'dependencies\pnpm\bin\pnpm.mjs'
$runtimeBin = Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\resources\runtime\bin'
$ghConfigDir = Join-Path $home_ '.config\gh-agent'

function Write-Step([string]$text) { Write-Host "superagent: $text" }

function Get-ServiceProcesses {
  $found = @()
  foreach ($process in Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue) {
    $commandLine = (Get-CimInstance Win32_Process -Filter "ProcessId = $($process.Id)" -ErrorAction SilentlyContinue).CommandLine
    if ($commandLine -and $commandLine -like "*$profileDir*") { $found += $process }
  }
  return $found
}

function Read-Token {
  if (-not (Test-Path $outLog)) { return $null }
  $match = Select-String -Path $outLog -Pattern 'token=([A-Za-z0-9_\-]+)' | Select-Object -Last 1
  if ($match) { return $match.Matches.Groups[1].Value }
  return $null
}

function Get-State {
  param([string]$Token)
  if (-not $Token) { return $null }
  try {
    $response = Invoke-WebRequest "$($Url.TrimEnd('/'))/orchestrator/api/state?token=$Token" `
      -Headers @{ 'x-orchestrator-request' = '1' } -TimeoutSec 3 -UseBasicParsing
    $value = $response.Content | ConvertFrom-Json
    $health = @{}
    $errors = @{}
    if ($value.health) {
      foreach ($entry in $value.health.PSObject.Properties) {
        $state = if ($entry.Value -is [System.Management.Automation.PSCustomObject]) { $entry.Value.state } else { $null }
        $health[$entry.Name] = $state
        if ($state -eq 'error') {
          $detail = if ($entry.Value.PSObject.Properties['detail']) { [string]$entry.Value.detail } else { '' }
          $errors[$entry.Name] = $detail
        }
      }
    }
    $setup = if ($value.setup) { $value.setup.problem } else { $null }
    $feishu = if ($value.setup) { $value.setup.feishuProblem } else { $null }
    return @{ health = $health; errors = $errors; setup = $setup; feishu = $feishu }
  } catch {
    return $null
  }
}

function Test-RuntimeUp {
  param($Current)
  if (-not $Current) { return $false }
  $state = $Current.health['runtime']
  return ($state -eq 'ready' -or $state -eq 'paused')
}

function Get-PartErrors {
  param($Current)
  if (-not $Current) { return @{} }
  $result = @{}
  foreach ($name in ($Current.errors.Keys | Sort-Object)) { if ($name -ne 'runtime') { $result[$name] = $Current.errors[$name] } }
  return $result
}

function Get-Outcome {
  param($Processes, $Current)
  if ($Processes.Count -ne 1 -or -not (Test-RuntimeUp $Current)) { return 1 }
  if ($Current.setup) { return 3 }
  if ((Get-PartErrors $Current).Count -gt 0) { return 2 }
  return 0
}

function Invoke-Status {
  $processes = @(Get-ServiceProcesses)
  $token = if ($processes.Count -eq 1) { Read-Token } else { $null }
  $current = if ($processes.Count -eq 1) { Get-State $token } else { $null }
  [pscustomobject]@{
    pids = @($processes | ForEach-Object { $_.Id })
    cwd = $root
    profile = $Profile
    url = $Url
    token = $token
    manually_stopped = (Test-Path $stopMarker)
    health = if ($current) { $current.health } else { $null }
    errors = if ($current) { $current.errors } else { $null }
    setup = if ($current) { $current.setup } else { $null }
    feishu = if ($current) { $current.feishu } else { $null }
  } | ConvertTo-Json -Depth 6
  $script:lastExit = Get-Outcome $processes $current
}

function Stop-Service {
  param([switch]$Intentional)
  $processes = @(Get-ServiceProcesses)
  if ($processes.Count -eq 0) { Write-Step "not running ($Profile)"; $script:lastExit = 0; return }
  if ($Intentional) { New-Item -ItemType File -Path $stopMarker -Force | Out-Null }
  foreach ($process in $processes) {
    Write-Step "stopping pid $($process.Id)"
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
  }
  $deadline = (Get-Date).AddSeconds($StopTimeout)
  while ((Get-Date) -lt $deadline -and @(Get-ServiceProcesses).Count -gt 0) { Start-Sleep -Milliseconds 500 }
  if (@(Get-ServiceProcesses).Count -gt 0) { Write-Step "still running after $StopTimeout s"; $script:lastExit = 1; return }
  # A killed host leaves the state lock behind, and the next start waits on it for thirty seconds.
  if (Test-Path $lockFile) { Remove-Item $lockFile -Recurse -Force -ErrorAction SilentlyContinue }
  Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
  Write-Step 'stopped'
  $script:lastExit = 0
}

function Start-Service {
  if ($RespectStop -and (Test-Path $stopMarker)) { Write-Step 'stopped by a person; not starting (-RespectStop)'; $script:lastExit = 1; return }
  $existing = @(Get-ServiceProcesses)
  if ($existing.Count -gt 0) { Write-Step "already running (pid $($existing[0].Id)); use restart"; $script:lastExit = 1; return }

  foreach ($path in @($exe, $asarFile, $profileDir, $runtimeRoot, $pnpmJs)) {
    if (-not (Test-Path $path)) { Write-Step "missing: $path"; $script:lastExit = 1; return }
  }
  if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
  if (Test-Path $lockFile) { Remove-Item $lockFile -Recurse -Force -ErrorAction SilentlyContinue }
  Remove-Item $stopMarker -Force -ErrorAction SilentlyContinue

  $env:ELECTRON_RUN_AS_NODE = '1'
  if (Test-Path $ghConfigDir) { $env:GH_CONFIG_DIR = $ghConfigDir }
  $arguments = @('--expose-internals', ('"' + $hostJs + '"'), ('"' + $asarRoot + '"'), ('"' + $profileDir + '"'),
    ('"' + $runtimeRoot + '"'), ('"' + $pnpmJs + '"'), ('"' + $runtimeBin + '"'))
  $process = Start-Process -FilePath $exe -ArgumentList $arguments -RedirectStandardOutput $outLog -RedirectStandardError $errLog `
    -NoNewWindow -PassThru
  Set-Content -Path $pidFile -Value $process.Id -Encoding UTF8
  Write-Step "started pid $($process.Id); waiting up to $Timeout s for the management API"

  $deadline = (Get-Date).AddSeconds($Timeout)
  while ((Get-Date) -lt $deadline) {
    if ($process.HasExited) { Write-Step "exited with $($process.ExitCode); see $errLog"; $script:lastExit = 1; return }
    $token = Read-Token
    $current = if ($token) { Get-State $token } else { $null }
    if (Test-RuntimeUp $current) {
      $shown = "$($Url.TrimEnd('/'))/?token=$token"
      Write-Step "ready: $shown"
      Write-Output $shown
      $script:lastExit = Get-Outcome @($process) $current
      return
    }
    Start-Sleep -Seconds 1
  }
  Write-Step "not ready after $Timeout s; see $outLog"
  $script:lastExit = 1
}

$database = Join-Path $stateDir 'orchestrator.sqlite'
$backupDir = Join-Path $stateDir 'backups'
$nodeExe = Join-Path $runtimeRoot 'dependencies\node\bin\node.exe'

# Copies the database with SQLite's own `VACUUM INTO`, which writes a consistent file even while the service runs.
function Invoke-Backup {
  if (-not (Test-Path $database)) { Write-Step "no database at $database"; $script:lastExit = 1; return }
  if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
  $target = Join-Path $backupDir ('orchestrator-{0}.sqlite' -f (Get-Date).ToString('yyyyMMdd-HHmmss'))
  $code = @'
const { DatabaseSync } = require('node:sqlite')
const [database, target] = process.argv.slice(2)
const literal = target.replace(/\\/g, '/').replace(/'/g, "''")
const db = new DatabaseSync(database)
db.exec(`VACUUM INTO '${literal}'`)
db.close()
'@
  $file = Join-Path $env:TEMP ('superagent-backup-{0}.cjs' -f [guid]::NewGuid().ToString('N'))
  Set-Content -Path $file -Value $code -Encoding UTF8
  try { & $nodeExe $file $database $target } catch { Write-Step "backup failed: $($_.Exception.Message)"; $script:lastExit = 1; return }
  finally { Remove-Item $file -Force -ErrorAction SilentlyContinue }
  if (-not (Test-Path $target)) { Write-Step 'backup wrote no file'; $script:lastExit = 1; return }
  # Keep the newest `Keep` files; a daily backup of a small database is cheap, an unbounded pile is not.
  Get-ChildItem $backupDir -File | Where-Object { $_.Name -match '^orchestrator-\d{8}-\d{6}\.sqlite$' } |
    Sort-Object Name -Descending | Select-Object -Skip $Keep |
    Remove-Item -Force -ErrorAction SilentlyContinue
  Write-Step ('backup: {0} ({1:N0} KB)' -f $target, ((Get-Item $target).Length / 1KB))
  $script:lastExit = 0
}

# Asks SQLite whether a file is a database it can read. A copy of a WAL-mode database taken without its log passes no such check.
function Test-Database([string]$file) {
  $code = @'
const { DatabaseSync } = require('node:sqlite')
const db = new DatabaseSync(process.argv[2], { readOnly: true })
const rows = db.prepare('PRAGMA integrity_check').all()
db.close()
process.stdout.write(rows.map(row => Object.values(row).join('')).join(';'))
'@
  $temp = Join-Path $env:TEMP ('superagent-check-{0}.cjs' -f [guid]::NewGuid().ToString('N'))
  Set-Content -Path $temp -Value $code -Encoding UTF8
  try { $result = & $nodeExe $temp $file } finally { Remove-Item $temp -Force -ErrorAction SilentlyContinue }
  return "$result" -eq 'ok'
}

# Stops the service, keeps the current database aside, puts the chosen backup in place, and starts again.
function Invoke-Restore {
  $source = if ($Backup) { $Backup } else {
    $newest = Get-ChildItem $backupDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^orchestrator-\d{8}-\d{6}\.sqlite$' } |
      Sort-Object Name -Descending |
      Select-Object -First 1
    if ($newest) { $newest.FullName } else { '' }
  }
  if (-not $source) { Write-Step 'no backup to restore'; $script:lastExit = 1; return }
  if (-not (Test-Path $source)) { Write-Step "missing: $source"; $script:lastExit = 1; return }
  # A file that does not read back would replace a working database with a broken one, so nothing is touched.
  if (-not (Test-Database $source)) { Write-Step "not a usable database: $source"; $script:lastExit = 1; return }
  # A restore is not a person stopping the service, so no marker is written and the watchdog may start it again.
  Stop-Service | Out-Null
  # The write-ahead log belongs to the database it was written for: left beside another file it corrupts that one.
  Remove-Item "$database-wal", "$database-shm" -Force -ErrorAction SilentlyContinue
  if (Test-Path $database) {
    $aside = Join-Path $backupDir ('orchestrator-before-restore-{0}.sqlite' -f (Get-Date).ToString('yyyyMMdd-HHmmss'))
    # A copy of the main file alone loses whatever is still in the log, so the aside is taken the way a backup is.
    $code = @'
const { DatabaseSync } = require('node:sqlite')
const [database, target] = process.argv.slice(2)
const literal = target.replace(/\\/g, '/').replace(/'/g, "''")
const db = new DatabaseSync(database)
db.exec(`VACUUM INTO '${literal}'`)
db.close()
'@
    $temp = Join-Path $env:TEMP ('superagent-aside-{0}.cjs' -f [guid]::NewGuid().ToString('N'))
    Set-Content -Path $temp -Value $code -Encoding UTF8
    try { & $nodeExe $temp $database $aside } catch { Write-Step "could not keep the current database: $($_.Exception.Message)" }
    finally { Remove-Item $temp -Force -ErrorAction SilentlyContinue }
    if (Test-Path $aside) { Write-Step "kept the current database at $aside" }
  }
  Copy-Item $source $database -Force
  if (-not (Test-Database $database)) { Write-Step 'the restored file does not read back; the previous one is kept aside'; $script:lastExit = 1; return }
  Write-Step "restored $source"
  Start-Service
  $script:lastExit = if ($script:lastExit -eq 0) { 0 } else { 1 }
}

if (-not (Test-Path $profileDir)) { Write-Step "no profile at $profileDir"; exit 1 }

$script:lastExit = 1
switch ($Action) {
  'status' { Invoke-Status; exit $script:lastExit }
  'url' { $token = Read-Token; if ($token) { "$($Url.TrimEnd('/'))/?token=$token"; exit 0 } else { Write-Step 'no token yet'; exit 1 } }
  'stop' { Stop-Service -Intentional; exit $script:lastExit }
  'backup' { Invoke-Backup; exit $script:lastExit }
  'restore' { Invoke-Restore; exit $script:lastExit }
  'start' { Start-Service; exit $script:lastExit }
  'restart' { Stop-Service -Intentional; if ($script:lastExit -ne 0) { exit $script:lastExit }; Start-Service; exit $script:lastExit }
}
