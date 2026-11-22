<#
.SYNOPSIS
  Tail Windows Codex CLI rollout JSONL -> agents-monitor ingest (same as codex-tail.sh).

.DESCRIPTION
  Polls %USERPROFILE%\.codex\sessions\**\rollout-*.jsonl every 2s and POSTs
  only new { ... } lines to https://agents-monitor.fly.dev/api/ingest.
  Adds "host" field (default win-<COMPUTERNAME>) so the server page can
  color/filter wsl vs win. Skips existing history, picks up new files.
  Server assigns server-side ordinal, so colliding ordinal:0 is safe.
#>
param(
  [string]$MonitorUrl = $(if ($env:MONITOR_URL) { $env:MONITOR_URL } else { "https://agents-monitor.fly.dev" }),
  [string]$IngestToken = $(if ($env:INGEST_TOKEN) { $env:INGEST_TOKEN } else { "" }),
  [string]$SessionsDir = $(Join-Path $env:USERPROFILE ".codex\sessions"),
  [string]$HostLabel = $(if ($env:HOST_LABEL) { $env:HOST_LABEL } else { "win-$env:COMPUTERNAME" }),
  [int]$PollSeconds = 2
)

$ErrorActionPreference = "Continue"
if ([string]::IsNullOrWhiteSpace($IngestToken)) {
  Write-Host "INGEST_TOKEN empty. Set `$env:INGEST_TOKEN or pass -IngestToken xxx" -ForegroundColor Red
  exit 1
}
$IngestToken = $IngestToken.Trim()
if ([string]::IsNullOrWhiteSpace($HostLabel)) { $HostLabel = "win-$env:COMPUTERNAME" }
$IngestUrl = ($MonitorUrl.TrimEnd('/') + "/api/ingest")
Write-Host "posting to $IngestUrl as host=$HostLabel  sessions=$SessionsDir" -ForegroundColor Green

$seen = @{}
Get-ChildItem -Path $SessionsDir -Filter "rollout-*.jsonl" -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
  try { $seen[$_.FullName] = (Get-Content $_.FullName -ErrorAction SilentlyContinue | Measure-Object -Line).Lines } catch {}
  if ($null -eq $seen[$_.FullName]) { $seen[$_.FullName] = 0 }
}

while ($true) {
  $files = Get-ChildItem -Path $SessionsDir -Filter "rollout-*.jsonl" -Recurse -File -ErrorAction SilentlyContinue
  foreach ($f in $files) {
    $last = 0
    if ($seen.ContainsKey($f.FullName)) { $last = [int]$seen[$f.FullName] }
    try { $lines = Get-Content $f.FullName -ErrorAction SilentlyContinue } catch { continue }
    if ($null -eq $lines) { $seen[$f.FullName] = 0; continue }
    $cur = @($lines).Count
    if ($cur -gt $last) {
      $newLines = @($lines)[$last..($cur - 1)]
      foreach ($line in $newLines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if (-not $line.TrimStart().StartsWith("{")) { continue }
        try { $o = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if (-not $o.host) { $o | Add-Member -NotePropertyName host -NotePropertyValue $HostLabel -Force }
        $body = ($o | ConvertTo-Json -Depth 20 -Compress)
        try {
          Invoke-RestMethod -Uri $IngestUrl -Method Post -Body $body `
            -ContentType "application/json" `
            -Headers @{ "X-Ingest-Token" = $IngestToken } -TimeoutSec 5 | Out-Null
        } catch {
          Write-Host "post failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
      }
      $seen[$f.FullName] = $cur
    }
  }
  Start-Sleep -Seconds $PollSeconds
}
