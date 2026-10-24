@echo off
setlocal
title Zomboid patches - MalcolmHShazam/Zomboid53Server_Patches
rem Downloads Malcolm's patch mods from GitHub and installs/updates them in %USERPROFILE%\Zomboid\mods.
rem No account, no git. Only folders listed in manifest.json are touched. Does not start the game.
powershell -NoProfile -ExecutionPolicy Bypass -Command "$s=[IO.File]::ReadAllText('%~f0'); $i=$s.IndexOf([char]10+'#__PS__'); iex $s.Substring($i+8)"
echo.
pause
exit /b
#__PS__
$ErrorActionPreference = 'Stop'
$owner = 'MalcolmHShazam'; $repo = 'Zomboid53Server_Patches'; $branch = 'main'
$url = "https://github.com/$owner/$repo/archive/refs/heads/$branch.zip"
$mods = Join-Path $env:USERPROFILE 'Zomboid\mods'
$tmp = Join-Path $env:TEMP ('ZomboidPatches_' + [guid]::NewGuid().ToString('N'))
Write-Host "Zomboid patches from github.com/$owner/$repo ($branch)" -ForegroundColor Cyan
Write-Host "Mods folder: $mods"
Write-Host ''
try {
  if (-not (Test-Path -LiteralPath $mods -PathType Container)) {
    New-Item -ItemType Directory -Path $mods -Force | Out-Null
    Write-Host "Created $mods (it didn't exist yet)." -ForegroundColor Yellow
  }
  New-Item -ItemType Directory -Path $tmp -Force | Out-Null
  $zip = Join-Path $tmp 'patches.zip'
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  Write-Host 'Downloading...'
  try { $ProgressPreference = 'SilentlyContinue'; Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip }
  catch { throw "Could not download the patches. Check your internet connection and try again.`n  ($url)`n  $($_.Exception.Message)" }
  Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $tmp 'x') -Force
  $root = Get-ChildItem -LiteralPath (Join-Path $tmp 'x') -Directory | Select-Object -First 1
  $mf = Join-Path $root.FullName 'manifest.json'
  if (-not (Test-Path -LiteralPath $mf)) { throw 'The download has no manifest.json; nothing has been published yet.' }
  $man = [IO.File]::ReadAllText($mf) | ConvertFrom-Json
  $n = @{ installed = 0; updated = 0; unchanged = 0; failed = 0 }
  foreach ($m in @($man.mods)) {
    $f = [string]$m.folder
    if ($f -notmatch '^[A-Za-z0-9_.\-]{1,80}$' -or $f -match '^\.+$') { Write-Host "  SKIPPED  bad folder name in manifest: $f" -ForegroundColor Red; $n.failed++; continue }
    $src = Join-Path $root.FullName $f; $dst = Join-Path $mods $f; $ver = Join-Path $dst '.zp_version'
    if (-not (Test-Path -LiteralPath $src -PathType Container)) { Write-Host "  MISSING  $f (listed but not in the download)" -ForegroundColor Red; $n.failed++; continue }
    $old = $null; if (Test-Path -LiteralPath $ver) { $old = ([IO.File]::ReadAllText($ver)).Trim() }
    if ($old -eq [string]$m.hash) { Write-Host "  unchanged  $f"; $n.unchanged++; continue }
    try {
      $existed = Test-Path -LiteralPath $dst
      if ($existed) { Remove-Item -LiteralPath $dst -Recurse -Force }
      Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
      [IO.File]::WriteAllText($ver, [string]$m.hash)
      if ($existed) { Write-Host "  UPDATED    $f" -ForegroundColor Green; $n.updated++ } else { Write-Host "  INSTALLED  $f" -ForegroundColor Green; $n.installed++ }
    } catch { Write-Host "  FAILED     $f : $($_.Exception.Message) (is the game running?)" -ForegroundColor Red; $n.failed++ }
  }
  Write-Host ''
  Write-Host ("Done: {0} installed, {1} updated, {2} unchanged{3}." -f $n.installed, $n.updated, $n.unchanged, $(if ($n.failed) { ", $($n.failed) failed" } else { '' })) -ForegroundColor Cyan
} catch {
  Write-Host ''
  Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
} finally {
  if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
