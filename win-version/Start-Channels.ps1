<#
.SYNOPSIS
  Start full bidirectional comms with agents-monitor in one script.

.DESCRIPTION
  Launches Codex-Tail.ps1 (session -> server page) and Queue-Poll.ps1
  (server page -> session) in two windows. Tail follows all sessions;
  the poller auto-attaches the latest session unless TargetThread is set.
#>
param(
  [string]$MonitorUrl = $(if ($env:MONITOR_URL) { $env:MONITOR_URL } else { "https://agents-monitor.fly.dev" }),
  [string]$IngestToken = $(if ($env:INGEST_TOKEN) { $env:INGEST_TOKEN } else { "" }),
  [string]$TargetThread = $(if ($env:TARGET_THREAD) { $env:TARGET_THREAD } else { "" })
)

$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($IngestToken)) {
  if (Get-Command fly -ErrorAction SilentlyContinue) {
    $tok = (fly ssh console -a agents-monitor --command "sh -c 'printenv INGEST_TOKEN'" 2>$null | Select-Object -Last 1)
    if ($tok) { $IngestToken = "$tok".Trim() }
  }
}
if ([string]::IsNullOrWhiteSpace($IngestToken)) {
  $IngestToken = Read-Host "Paste INGEST_TOKEN"
}
$env:MONITOR_URL = $MonitorUrl
$env:INGEST_TOKEN = $IngestToken
if (-not [string]::IsNullOrWhiteSpace($TargetThread)) { $env:TARGET_THREAD = $TargetThread }

Start-Process powershell -ArgumentList "-NoExit", "-ExecutionPolicy", "Bypass", "-File", "$dir\Codex-Tail.ps1"
Start-Process powershell -ArgumentList "-NoExit", "-ExecutionPolicy", "Bypass", "-File", "$dir\Queue-Poll.ps1"
Write-Host "both channels launched in separate windows (tail + poll). Close the windows to stop." -ForegroundColor Green
