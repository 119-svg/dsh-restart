# Fully restart DSH Desktop -- same effect as quitting from the tray and opening it again.
#
# Three roles in one file:
#   phase 1 (no switch)   : write the pending marker, launch the worker and the guard, exit at once.
#   worker  (-Detached)   : wait for the caller's HTTP response, try a graceful window close, force-kill
#                           the app tree, wait until nothing is left, relaunch, verify the window is back.
#   guard   (-Guard)      : safety net. If the marker is still there after the delay and no app process
#                           exists, the worker died mid-flight -- relaunch here.
#
# Why the worker is launched through WMI (Win32_Process.Create) instead of Start-Process:
# a child spawned by a DSH plugin lives inside DSH's managed subprocess containment, and that
# containment is torn down when the host exits -- so a plain child dies exactly when it runs the
# taskkill, and the app never comes back (observed 2026-10-07 16:22:38: the app closed, the worker
# vanished, no relaunch line ever reached the log). A WMI-created process is parented to
# WmiPrvSE.exe, outside that containment, so it survives. Start-Process stays as fallback.
#
# Usage:
#   restart-dsh.ps1                 restart (this is what restart-dsh.cmd and the plugin button call)
#   restart-dsh.ps1 -DryRun         log the plan and process list only; kills and starts nothing
#
# Everything is appended to ~/.dsh/dsh-restart.log. Messages are ASCII on purpose: Windows PowerShell
# 5.1 reads a BOM-less UTF-8 .ps1 with the ANSI code page, so non-ASCII log lines would come out garbled.

[CmdletBinding()]
param(
  [switch]$Detached,
  [switch]$Guard,
  [switch]$DryRun,
  [int]$GuardDelaySec = 30
)

$ErrorActionPreference = 'Continue'

$exe       = Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\DeepSeek Harness.exe'
$log       = Join-Path $env:USERPROFILE '.dsh\dsh-restart.log'
$pending   = Join-Path $env:USERPROFILE '.dsh\dsh-restart.pending'
$taskkill  = Join-Path $env:SystemRoot 'System32\taskkill.exe'
$procName  = 'DeepSeek Harness'
$procExe   = 'DeepSeek Harness.exe'

function W($m) {
  $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
  try { Add-Content -LiteralPath $log -Value $line -Encoding UTF8 } catch {}
  if (-not $Detached -and -not $Guard) { Write-Host $line }
}

function Get-AppProcesses { @(Get-Process -Name $procName -ErrorAction SilentlyContinue) }

function Show-Processes($list) {
  if ($list.Count -eq 0) { return 'none' }
  return (($list | ForEach-Object { $_.Id }) -join ',')
}

function Clear-Pending {
  try { Remove-Item -LiteralPath $pending -Force -ErrorAction Stop } catch {}
}

# Launch this same script as a detached role outside DSH's subprocess containment.
function Start-Outside([string]$roleSwitch, [string]$label) {
  if ([string]::IsNullOrEmpty($PSCommandPath)) { W ('cannot resolve this script path, aborting ' + $label); return $false }
  $extra = ''
  if ($DryRun) { $extra = ' -DryRun' }
  if ($roleSwitch -eq '-Guard') { $extra += (' -GuardDelaySec ' + $GuardDelaySec) }
  $cmdline = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '" ' + $roleSwitch + $extra
  try {
    $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmdline }
    if ($r.ReturnValue -eq 0) {
      W ($label + ' launched outside containment (wmi pid ' + $r.ProcessId + ')')
      return $true
    }
    W ($label + ': wmi create returned ' + $r.ReturnValue + '; falling back to Start-Process')
  } catch {
    W ($label + ': wmi create failed (' + $_.Exception.Message + '); falling back to Start-Process')
  }
  try {
    $fallback = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '" ' + $roleSwitch + $extra
    Start-Process -FilePath 'powershell.exe' -ArgumentList $fallback -WindowStyle Hidden -ErrorAction Stop | Out-Null
    W ($label + ' launched via Start-Process (still inside containment; may die with the app)')
    return $true
  } catch {
    W ($label + ': Start-Process failed: ' + $_.Exception.Message)
    return $false
  }
}

# ------------------------------------------------------------------ phase 1
if (-not $Detached -and -not $Guard) {
  W '=== restart requested (phase 1) ==='
  if (-not (Test-Path -LiteralPath $exe)) {
    W ('exe not found, aborting: ' + $exe)
    exit 1
  }
  if ($DryRun) {
    $list = Get-AppProcesses
    W 'DRY RUN: would write the pending marker and launch worker + guard outside containment'
    W ('DRY RUN: app processes = ' + $list.Count + ' (' + (Show-Processes $list) + ')')
    W '=== end (dry run) ==='
    exit 0
  }
  try { Set-Content -LiteralPath $pending -Value (Get-Date -Format o) -Encoding UTF8 -ErrorAction Stop } catch {
    W ('could not write the pending marker: ' + $_.Exception.Message)
  }
  $okWorker = Start-Outside '-Detached' 'worker'
  Start-Outside '-Guard' 'guard' | Out-Null
  if (-not $okWorker) { W 'worker could not be launched; the guard is the only hope'; exit 1 }
  exit 0
}

# ------------------------------------------------------------------ guard
if ($Guard) {
  Start-Sleep -Seconds $GuardDelaySec
  if (-not (Test-Path -LiteralPath $pending)) {
    W 'guard: no pending restart, nothing to do'
    exit 0
  }
  $now = Get-AppProcesses
  if ($now.Count -gt 0) {
    W ('guard: app is running (' + (Show-Processes $now) + '), clearing marker')
    Clear-Pending
    exit 0
  }
  W 'guard: marker still pending and no app process -- the worker died mid-flight, relaunching now'
  try {
    Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe) -ErrorAction Stop | Out-Null
    W 'guard: relaunch issued'
  } catch {
    W ('guard: relaunch failed: ' + $_.Exception.Message)
  }
  Start-Sleep -Seconds 20
  $after = Get-AppProcesses
  W ('guard: after relaunch = ' + $after.Count + ' processes (' + (Show-Processes $after) + ')')
  Clear-Pending
  W '=== guard end ==='
  exit 0
}

# ------------------------------------------------------------------ worker
W '=== restart running (worker, outside containment) ==='
$before = Get-AppProcesses
W ('before: ' + $before.Count + ' processes (' + (Show-Processes $before) + ')')
W ('exe: ' + $exe + ' (exists=' + (Test-Path -LiteralPath $exe) + ')')

if ($DryRun) {
  W 'DRY RUN: would close the main window gracefully, kill the rest with taskkill /T /F, wait, then relaunch'
  W '=== end (dry run) ==='
  exit 0
}

# 1) give the caller's HTTP response time to reach the browser before the app disappears
Start-Sleep -Milliseconds 1000

# 2) graceful attempt: closing the main window is the closest external equivalent of a quit.
# The official shell only hides the window to the tray instead of quitting, so do not sit out a
# fixed wait: stop the moment the window is gone and let the force kill below do the real work.
$main = $before | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if ($main) {
  try {
    $asked = $main.CloseMainWindow()
    W ('graceful close requested on pid ' + $main.Id + ' -> ' + $asked)
  } catch {
    W ('graceful close failed: ' + $_.Exception.Message)
  }
  for ($i = 0; $i -lt 10; $i++) {
    Start-Sleep -Milliseconds 200
    if ((Get-AppProcesses).Count -eq 0) {
      W 'app exited after the graceful close'
      break
    }
    $p = Get-Process -Id $main.Id -ErrorAction SilentlyContinue
    if ($null -eq $p -or $p.MainWindowHandle -eq 0) {
      W 'main window is gone (hid to tray); skipping the rest of the graceful wait'
      break
    }
  }
} else {
  W 'no process with a main window; skipping the graceful step'
}

# 3) force: terminate every app process and its children
if ((Get-AppProcesses).Count -gt 0) {
  W ("taskkill /IM '" + $procExe + "' /T /F")
  & $taskkill /IM $procExe /T /F 2>&1 | ForEach-Object { W ('taskkill> ' + $_) }
} else {
  W 'app already exited after the graceful step'
}

# 4) wait until the process tree is really gone
$waited = 0
for ($i = 0; $i -lt 40; $i++) {
  Start-Sleep -Milliseconds 500
  $waited += 500
  if ((Get-AppProcesses).Count -eq 0) { break }
}
$left = Get-AppProcesses
W ('after ' + $waited + 'ms: remaining = ' + $left.Count + ' (' + (Show-Processes $left) + ')')
if ($left.Count -gt 0) {
  W 'note: leftovers may hold the single-instance lock; the relaunch below may fail'
}

# 5) settle: let the single-instance lock and the loopback port go (the tree is already gone, so this
# only needs to cover the lock release)
Start-Sleep -Milliseconds 500

# 6) relaunch
$launched = $false
try {
  Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe) -ErrorAction Stop | Out-Null
  $launched = $true
  W 'relaunch issued'
} catch {
  W ('relaunch failed: ' + $_.Exception.Message)
}

# 7) verify the window comes back
$windowBack = $false
for ($i = 1; $i -le 60; $i++) {
  Start-Sleep -Milliseconds 1000
  $now = Get-AppProcesses
  if (($now | Where-Object { $_.MainWindowHandle -ne 0 }).Count -gt 0) {
    W ('window is back after ' + $i + 's (' + (Show-Processes $now) + ')')
    $windowBack = $true
    break
  }
}
if ($windowBack) {
  Clear-Pending
  W 'pending marker cleared'
} else {
  W ('no window within 60s (launched=' + $launched + ', processes=' + (Show-Processes (Get-AppProcesses)) + ')')
  W 'the guard will try again if it is still armed'
  if (-not $launched) {
    try {
      Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe) -ErrorAction Stop | Out-Null
      W 'retry relaunch issued'
    } catch {
      W ('retry failed: ' + $_.Exception.Message)
    }
  }
}
W '=== end ==='
