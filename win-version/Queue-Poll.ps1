<#
.SYNOPSIS
  Poll agents-monitor message queue and deliver to a Codex CLI session.

.DESCRIPTION
  Polls https://agents-monitor.fly.dev/get (oldest-first, pop semantics)
  and delivers each message via `codex queue --thread <session> --message <text>`.
  Auto-attaches the latest local session if TargetThread is unset.
  Mirror of queue-poll.sh.

.EXAMPLE
  .\Queue-Poll.ps1
  .\Queue-Poll.ps1 -TargetThread "01a200e1-2c75-7590-a3c8-5c956b0d68ae"
  .\Queue-Poll.ps1 -Once -DryRun   # fetch + print without delivering
#>
param(
  [string]$MonitorUrl = $(if ($env:MONITOR_URL) { $env:MONITOR_URL } else { "https://agents-monitor.fly.dev" }),
  [string]$IngestToken = $(if ($env:INGEST_TOKEN) { $env:INGEST_TOKEN } else { "" }),
  [string]$TargetThread = $(if ($env:TARGET_THREAD) { $env:TARGET_THREAD } else { "" }),
  [int]$PollSeconds = 2,
  [switch]$Once,
  [switch]$DryRun
)

$ErrorActionPreference = "Continue"
if ([string]::IsNullOrWhiteSpace($IngestToken)) {
  Write-Host "INGEST_TOKEN empty. Set `$env:INGEST_TOKEN or pass -IngestToken xxx" -ForegroundColor Red
  exit 1
}
$IngestToken = $IngestToken.Trim()
if ([string]::IsNullOrWhiteSpace($TargetThread)) {
  $latest = Get-ChildItem -Path (Join-Path $env:USERPROFILE ".codex\sessions") -Filter "rollout-*.jsonl" -Recurse -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($latest) {
    $m = [regex]::Matches($latest.Name, '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')
    if ($m.Count -gt 0) { $TargetThread = $m[$m.Count - 1].Value }
  }
  if ([string]::IsNullOrWhiteSpace($TargetThread)) {
    Write-Host "no Codex session found and TargetThread unset" -ForegroundColor Red
    exit 1
  }
  Write-Host "TargetThread auto-detected: $TargetThread"
}
$base = $MonitorUrl.TrimEnd('/')
Write-Host "polling $base/get as target=$TargetThread (token len $($IngestToken.Length))"

while ($true) {
  $url = "$base/get?session_id=$TargetThread"
  try {
    $r = Invoke-RestMethod -Uri $url -Headers @{ "X-Ingest-Token" = $IngestToken } -TimeoutSec 10
  } catch {
    Write-Host "poll failed: $($_.Exception.Message)" -ForegroundColor Yellow
    if ($Once) { break }
    Start-Sleep -Seconds $PollSeconds
    continue
  }
  if (-not $r.msg) {
    if ($Once) { Write-Host "queue empty" }
    else { Start-Sleep -Seconds $PollSeconds }
    if ($Once) { break }
    continue
  }
  $sid = [string]$r.msg.session_id
  if ([string]::IsNullOrWhiteSpace($sid)) { $sid = $TargetThread }
  $text = [string]$r.msg.text
  if ($DryRun) {
    Write-Host "DRY msg=$($r.msg.id) session=$sid text=$($text.Substring(0, [Math]::Min(200, $text.Length)))"
  } else {
    Write-Host "delivering msg=$($r.msg.id) to $sid"
    try {
      & codex queue --thread $sid --message $text 2>&1 | Out-String | Write-Host
      Write-Host "queued ok" -ForegroundColor Green
    } catch {
      Write-Host "codex queue failed for $sid" -ForegroundColor Red
    }
  }
  if ($Once) { break }
  Start-Sleep -Seconds 1
}
