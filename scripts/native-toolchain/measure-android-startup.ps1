param(
  [Parameter(Mandatory=$true)][string]$Apk,
  [Parameter(Mandatory=$true)][string]$Output,
  [Parameter(Mandatory=$true)][string]$BuildId,
  [Parameter(Mandatory=$true)][string]$RoundId,
  [Parameter(Mandatory=$true)][ValidatePattern('^[a-f0-9]{64}$')][string]$ConfigurationSha256,
  [ValidatePattern('^emulator-[0-9]+$')][string]$Serial='emulator-5554',
  [ValidateRange(20,100)][int]$Count=20
)
$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $PSScriptRoot 'source-contract.ps1')
$apkPath=Assert-WorkspacePath -Workspace $workspace -Path $Apk -PathType File
$outputPath=Assert-WorkspacePath -Workspace $workspace -Path $Output -PathType File -AllowMissing
$qaRoot=(Join-Path $workspace '.qa')+[IO.Path]::DirectorySeparatorChar
if (!$outputPath.StartsWith($qaRoot,[StringComparison]::OrdinalIgnoreCase)) { throw 'Measurements must be written under the owned .qa directory.' }
$adb=Join-Path $workspace '.tools/android-sdk/platform-tools/adb.exe'
$package='com.jianzhang.ledger'
$activity=$package+'/.MainActivity'
$hash=(Get-FileHash -LiteralPath $apkPath -Algorithm SHA256).Hash.ToLowerInvariant()
$manifestPath=Assert-WorkspacePath -Workspace $workspace -Path (Join-Path $workspace 'releases/android/release-manifest-2.0.0.json') -PathType File
$releaseManifestHash=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
$manifest=Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.schemaVersion -ne 2) { throw 'Verified release provenance is required.' }
$releaseHash=$manifest.sha256
if (!$releaseHash) { $releaseHash=$manifest.apk.sha256 }
if ($releaseHash -ne $hash) { throw 'Requested APK does not match the verified release artifact.' }
$sourceManifestPath=Assert-WorkspacePath -Workspace $workspace -Path (Join-Path $workspace 'releases/android/source-manifest-2.0.0.json') -PathType File
$sourceManifestHash=(Get-FileHash -LiteralPath $sourceManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
$sourceManifest=Get-Content -LiteralPath $sourceManifestPath -Raw | ConvertFrom-Json
if ($sourceManifest.sha256 -ne $manifest.sourceSha256) { throw 'Release source manifest identity differs.' }
Assert-FileContract $sourceManifest (Get-ClientSourceContract -Root (Join-Path $workspace 'clients/flutter') -Platform android) 'Measured Android release sources'
function Invoke-Adb([string[]]$Arguments) {
  $result=@(& $adb -s $Serial @Arguments 2>&1)
  if ($LASTEXITCODE -ne 0) { throw "ADB failed ($LASTEXITCODE): $($Arguments -join ' '): $($result -join ' ')" }
  return $result
}
function Convert-AndroidDuration([string]$Text) {
  if ($Text -notmatch '^\+(?:(?<h>\d+)h)?(?:(?<m>\d+)m)?(?:(?<s>\d+)s)?(?:(?<ms>\d+)ms)?$') { throw "Unrecognized Android duration: $Text" }
  return ([double]$Matches.h*3600000+[double]$Matches.m*60000+[double]$Matches.s*1000+[double]$Matches.ms)
}
New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($outputPath)) | Out-Null
function Assert-InstalledArtifact {
  $paths=@(Invoke-Adb @('shell','pm','path',$package))
  if ($paths.Count -ne 1 -or $paths[0] -notmatch '^package:(/data/app/[^\r\n]+/base\.apk)$') { throw 'A single installed release base APK is required.' }
  $installedPath=$Matches[1]
  $ownedRoot=Join-Path $qaRoot ('android-startup-'+[Guid]::NewGuid().ToString('N'))
  $ownedRoot=Assert-WorkspacePath -Workspace $workspace -Path $ownedRoot -PathType Directory -AllowMissing
  New-Item -ItemType Directory -Path $ownedRoot -ErrorAction Stop | Out-Null
  $ownedRoot=Assert-WorkspacePath -Workspace $workspace -Path $ownedRoot -PathType Directory
  $installedCopy=Assert-WorkspacePath -Workspace $workspace -Path (Join-Path $ownedRoot 'base.apk') -PathType File -AllowMissing
  try {
    Invoke-Adb @('pull',$installedPath,$installedCopy) | Out-Null
    $installedCopy=Assert-WorkspacePath -Workspace $workspace -Path $installedCopy -PathType File
    if ((Get-FileHash -LiteralPath $installedCopy -Algorithm SHA256).Hash.ToLowerInvariant() -ne $hash) { throw 'Installed APK differs from the verified release artifact.' }
  } finally {
    if (Test-Path -LiteralPath $installedCopy -PathType Leaf) {
      Assert-WorkspacePath -Workspace $workspace -Path $installedCopy -PathType File | Out-Null
      Remove-Item -LiteralPath $installedCopy
    }
    Assert-WorkspacePath -Workspace $workspace -Path $ownedRoot -PathType Directory | Out-Null
    Remove-Item -LiteralPath $ownedRoot
  }
}
Assert-InstalledArtifact
$api=[int](@(Invoke-Adb @('shell','getprop','ro.build.version.sdk'))[0])
$pageSize=[int](@(Invoke-Adb @('shell','getconf','PAGE_SIZE'))[0])
function Get-DeviceRuntime {
  $memory=@(Invoke-Adb @('shell','cat','/proc/meminfo')) | Where-Object { $_ -match '^MemTotal:\s+([0-9]+)\s+kB' } | Select-Object -First 1
  if (!$memory -or $memory -notmatch '^MemTotal:\s+([0-9]+)\s+kB') { throw 'Actual guest memory could not be observed.' }
  $memTotalKB=[long]$Matches[1]
  $renderer=@(Invoke-Adb @('shell','dumpsys','SurfaceFlinger')) | Where-Object { $_ -match '^\s*GLES:' } | Select-Object -First 1
  if (!$renderer) { throw 'Actual renderer could not be observed.' }
  return @{observedAt=[DateTimeOffset]::UtcNow.ToString('o');avdName=(@(Invoke-Adb @('shell','getprop','ro.boot.qemu.avd_name'))[0]).Trim();guestMemTotalKB=$memTotalKB;guestPageBytes=[int](@(Invoke-Adb @('shell','getconf','PAGE_SIZE'))[0]);onlineCpuCount=[int](@(Invoke-Adb @('shell','getconf','_NPROCESSORS_ONLN'))[0]);size=@(Invoke-Adb @('shell','wm','size'));density=@(Invoke-Adb @('shell','wm','density'));renderer=$renderer.Trim()}
}
$runtimeBefore=Get-DeviceRuntime
$samples=[Collections.Generic.List[double]]::new()
$logs=[Collections.Generic.List[object]]::new()
$startedAt=[DateTimeOffset]::UtcNow.ToString('o')
for ($sample=0;$sample -lt $Count;$sample++) {
  Invoke-Adb @('shell','am','force-stop',$package) | Out-Null
  $remaining=@(Invoke-Adb @('shell','sh','-c',"'pidof $package || true'"))
  if (($remaining -join '').Trim()) { throw 'App process remained alive after force-stop.' }
  $logInfo=[Diagnostics.ProcessStartInfo]::new()
  $logInfo.FileName=$adb
  # A fresh stream and app PID association avoid relying on logcat -c, which some AVDs reject.
  $logInfo.Arguments="-s $Serial logcat -b main -b system -v epoch -T 1 flutter:I ActivityManager:I ActivityTaskManager:I JianzhangQA:I *:S"
  $logInfo.UseShellExecute=$false
  $logInfo.RedirectStandardOutput=$true
  $logInfo.RedirectStandardError=$true
  $logInfo.CreateNoWindow=$true
  $stream=[Diagnostics.Process]::new()
  $stream.StartInfo=$logInfo
  $lines=[Collections.Generic.List[string]]::new()
  $launchClock=[Diagnostics.Stopwatch]::StartNew()
  $nativeMs=$null
  $fullyDrawnMs=$null
  $newPid=$null
  $streamStarted=$false
  try {
    if (!$stream.Start()) { throw 'Could not start the owned log reader.' }
    $streamStarted=$true
    $stderr=$stream.StandardError.ReadToEndAsync()
    $launchToken='cold-'+[Guid]::NewGuid().ToString('N')
    Invoke-Adb @('shell','log','-p','i','-t','JianzhangQA',$launchToken) | Out-Null
    $launch=Invoke-Adb @('shell','am','start','-W','-n',$activity)
    if (($launch -join "`n") -notmatch '(?m)^Status: ok\s*$') { throw 'Native activity did not start successfully.' }
    $newPid=(@(Invoke-Adb @('shell','pidof',$package)) -join '').Trim()
    if ($newPid -notmatch '^\d+$') { throw 'Native app PID is missing or ambiguous.' }
    $pendingRead=$null
    $seenLaunchMarker=$false
    while ($launchClock.ElapsedMilliseconds -lt 15000 -and ($null -eq $nativeMs -or $null -eq $fullyDrawnMs)) {
      if ($null -eq $pendingRead) { $pendingRead=$stream.StandardOutput.ReadLineAsync() }
      if (!$pendingRead.Wait(100)) { continue }
      $line=$pendingRead.Result
      $pendingRead=$null
      if ($null -eq $line) { throw 'Log stream exited before rendered-home readiness.' }
      $lines.Add($line)
      if ($line.Contains($launchToken)) { $seenLaunchMarker=$true }
      if ($seenLaunchMarker -and $line -match "^\s*\d+\.\d+\s+$newPid\s+\d+\s+[IVD]\s+flutter\s*:\s*jianzhang.native_ready_ms=(\d+)") { $nativeMs=[double]$Matches[1] }
      if ($seenLaunchMarker -and $line -match "Fully drawn $([regex]::Escape($activity)): (\+[^\s]+)") { $fullyDrawnMs=Convert-AndroidDuration $Matches[1] }
      if ($line -match 'FATAL EXCEPTION|E/flutter|Unhandled Exception') { throw "App failed during startup: $line" }
    }
    if ($null -eq $nativeMs -or $null -eq $fullyDrawnMs) { throw 'Native ledger-loaded rendered-home readiness timed out.' }
    $samples.Add($fullyDrawnMs)
    $logs.Add(@{index=$sample;pid=[int]$newPid;fullyDrawnMs=$fullyDrawnMs;nativeMs=$nativeMs;observerMs=$launchClock.Elapsed.TotalMilliseconds;launch=$launch;log=$lines.ToArray()})
    Write-Host "Android cold sample $($sample+1)/${Count}: fully drawn $fullyDrawnMs ms, native $nativeMs ms."
  } finally {
    if ($streamStarted -and !$stream.HasExited) { $stream.Kill(); $stream.WaitForExit() }
    $stream.Dispose()
    Invoke-Adb @('shell','am','force-stop',$package) | Out-Null
  }
}
Assert-InstalledArtifact
if ((Get-FileHash -LiteralPath $apkPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $hash) { throw 'Release APK changed during sampling.' }
$sorted=@($samples.ToArray() | Sort-Object)
$p95=$sorted[[Math]::Ceiling($sorted.Count*0.95)-1]
Assert-FileContract $sourceManifest (Get-ClientSourceContract -Root (Join-Path $workspace 'clients/flutter') -Platform android) 'Android release sources after sampling'
if ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $releaseManifestHash -or
    (Get-FileHash -LiteralPath $sourceManifestPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sourceManifestHash) { throw 'Android release or source manifest changed during sampling.' }
$runtimeAfter=Get-DeviceRuntime
$result=@{schemaVersion=1;buildId=$BuildId;roundId=$RoundId;metric='androidEmulatorColdStartP95Ms';mode='release';platform='android';configurationSha256=$ConfigurationSha256;apkSha256=$hash;releaseManifestSha256=$releaseManifestHash;sourceManifestSha256=$sourceManifestHash;sourceSha256=$sourceManifest.sha256;serial=$Serial;api=$api;pageSize=$pageSize;deviceRuntimeBefore=$runtimeBefore;deviceRuntimeAfter=$runtimeAfter;startedAt=$startedAt;finishedAt=[DateTimeOffset]::UtcNow.ToString('o');samples=$samples.ToArray();p95=$p95;method='force-stop; AMS Fully drawn after ledger-loaded renderer frame; native callback and new PID corroboration';logs=$logs.ToArray()}
$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $outputPath -Encoding utf8
if ($p95 -gt 5000) { throw "Android emulator cold-start p95 failed: $p95 ms." }
Write-Host "Android release cold-start p95 passed: $p95 ms ($Count samples)."
