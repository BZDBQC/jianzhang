param(
  [Parameter(Mandatory=$true)][string]$Executable,
  [Parameter(Mandatory=$true)][string]$Output,
  [Parameter(Mandatory=$true)][string]$BuildId,
  [Parameter(Mandatory=$true)][string]$RoundId,
  [Parameter(Mandatory=$true)][string]$PayloadManifest,
  [Parameter(Mandatory=$true)][ValidatePattern('^[a-f0-9]{64}$')][string]$ConfigurationSha256,
  [ValidateRange(20,100)][int]$Count=20
)
$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$exe=[IO.Path]::GetFullPath($Executable)
$outputFile=[IO.Path]::GetFullPath($Output)
if(!$exe.StartsWith($workspace+'\',[StringComparison]::OrdinalIgnoreCase) -or
   !$outputFile.StartsWith((Join-Path $workspace '.qa')+'\',[StringComparison]::OrdinalIgnoreCase)) {
  throw 'Startup measurements require an owned executable and .qa output.'
}
if(!(Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'Executable is missing.' }
. (Join-Path $PSScriptRoot 'source-contract.ps1')
$exe=Assert-WorkspacePath -Workspace $workspace -Path $exe -PathType File
$outputFile=Assert-WorkspacePath -Workspace $workspace -Path $outputFile -PathType File -AllowMissing
$buildManifestPath=Assert-WorkspacePath -Workspace $workspace -Path (Join-Path $workspace '.tools/windows-build-manifest.json') -PathType File
$buildManifestHash=(Get-FileHash -LiteralPath $buildManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
$manifest=Get-Content -LiteralPath $buildManifestPath -Raw | ConvertFrom-Json
if($manifest.schemaVersion -ne 2) { throw 'Current verified release build manifest is required.' }
Assert-FileContract $manifest.source (Get-ClientSourceContract -Root (Join-Path $workspace 'clients/flutter') -Platform windows) 'Measured release sources'
$recorded=@($manifest.payload.files | Where-Object {$_.path -eq 'jianzhang.exe'})
if($recorded.Count -ne 1 -or (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant() -ne $recorded[0].sha256) { throw 'Measured executable is not the recorded release binary.' }
$payloadManifestPath=[IO.Path]::GetFullPath($PayloadManifest)
$payloadManifestPath=Assert-WorkspacePath -Workspace $workspace -Path $payloadManifestPath -PathType File
$delivery=Get-Content -LiteralPath $payloadManifestPath -Raw | ConvertFrom-Json
if($delivery.schemaVersion -ne 2 -or !$delivery.payload -or !$delivery.crt) { throw 'Verified complete installer payload manifest is required.' }
Assert-FileContract $manifest.source $delivery.source 'Installer source provenance'
Assert-FileContract $manifest.payload $delivery.buildPayload 'Installer release build provenance'
$installer=Assert-WorkspacePath -Workspace $workspace -Path $delivery.installer -PathType File
if((Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant() -ne $delivery.sha256) { throw 'Recorded installer is changed.' }
$measurementRoot=[IO.Path]::GetDirectoryName($exe)
function Assert-MeasurementPayload {
  $actualFiles=@(Get-TreeFiles -Root $measurementRoot)
  $indexed=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
  foreach($file in $actualFiles) { $indexed.Add($file.FullName.Substring($measurementRoot.Length+1).Replace('\','/'),$file) }
  $selected=@(foreach($expected in $delivery.payload.files) {
    if(!$indexed.ContainsKey($expected.path)) { throw "Measured payload is missing: $($expected.path)" }
    $indexed[$expected.path]
  })
  Assert-FileContract $delivery.payload (Get-FileListContract -Root $measurementRoot -Files $selected) 'Complete measured engine, AOT, plugins, CRT and assets'
}
Assert-MeasurementPayload
$payloadManifestHash=(Get-FileHash -LiteralPath $payloadManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($outputFile)) | Out-Null
$samples=[Collections.Generic.List[double]]::new()
$nativeSamples=[Collections.Generic.List[int]]::new()
$logs=[Collections.Generic.List[object]]::new()
$hash=(Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant()
for($sample=0;$sample -lt $Count;$sample++) {
  $startInfo=[Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName=$exe
  $startInfo.WorkingDirectory=[IO.Path]::GetDirectoryName($exe)
  $startInfo.UseShellExecute=$false
  $startInfo.RedirectStandardOutput=$true
  $startInfo.RedirectStandardError=$true
  $startInfo.CreateNoWindow=$true
  $startInfo.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
  $process=[Diagnostics.Process]::new()
  $started=$false
  $process.StartInfo=$startInfo
  $lines=[Collections.Generic.List[string]]::new()
  $clock=[Diagnostics.Stopwatch]::StartNew()
  try {
    if(!$process.Start()) { throw 'Could not start native app.' }
    $started=$true
    $stderr=$process.StandardError.ReadToEndAsync()
    $ready=$null
    while($clock.ElapsedMilliseconds -lt 15000) {
      $read=$process.StandardOutput.ReadLineAsync()
      $remaining=[Math]::Max(1,15000-$clock.ElapsedMilliseconds)
      if(!$read.Wait([int]$remaining)) { throw 'Native rendered-home readiness timed out.' }
      $line=$read.Result
      if($null -eq $line) { throw 'Native app exited without rendered-home readiness.' }
      $lines.Add($line)
      if($line.StartsWith('JIANZHANG_READY ')) {
        $ready=$line.Substring(16) | ConvertFrom-Json
        break
      }
    }
    if(!$ready -or $ready.rendererFirstFrame -ne $true -or $ready.readyMs -isnot [long] -and $ready.readyMs -isnot [int] -or $ready.readyMs -lt 0) {
      throw 'Readiness must confirm the native renderer after ledger load.'
    }
    $elapsed=$clock.Elapsed.TotalMilliseconds
    $samples.Add($elapsed)
    $nativeSamples.Add([int]$ready.readyMs)
    $logs.Add(@{index=$sample;pid=$process.Id;externalMs=$elapsed;nativeMs=$ready.readyMs;stdout=$lines.ToArray()})
    if(!$process.CloseMainWindow()) { throw 'Native app did not expose a closeable main window.' }
    if(!$process.WaitForExit(5000)) { throw 'Native app failed to close cleanly.' }
    if($process.ExitCode -ne 0) { throw "Native app exited with $($process.ExitCode)." }
  } finally {
    # Only this measurement's child may be terminated on a failed run.
    if($started -and !$process.HasExited) { $process.Kill(); $process.WaitForExit() }
    $process.Dispose()
  }
}
if((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant() -ne $hash) { throw 'Executable changed during measurements.' }
Assert-MeasurementPayload
if((Get-FileHash -LiteralPath $payloadManifestPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $payloadManifestHash) { throw 'Payload manifest changed during measurements.' }
if((Get-FileHash -LiteralPath $buildManifestPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $buildManifestHash) { throw 'Build provenance changed during measurements.' }
Assert-FileContract $manifest.source (Get-ClientSourceContract -Root (Join-Path $workspace 'clients/flutter') -Platform windows) 'Measured release sources after sampling'
$sorted=@($samples | Sort-Object)
$p95=$sorted[[Math]::Ceiling($Count*.95)-1]
@{metric='windowsColdStartP95Ms';roundId=$RoundId;buildId=$BuildId;mode='release';configurationSha256=$ConfigurationSha256;sampleCount=$Count;p95Ms=$p95;samples=$samples.ToArray();nativeSamples=$nativeSamples.ToArray();executable=$exe;sha256=$hash;payloadSha256=$delivery.payload.sha256;installerSha256=$delivery.sha256;payloadManifestSha256=$payloadManifestHash;method='fresh process launch through native post-ledger rendered-frame marker; no OS cache purge';launches=$logs.ToArray()} |
  ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $outputFile -Encoding utf8
Write-Host "Windows fresh-process startup p95: $p95 ms ($Count samples)."
$global:LASTEXITCODE=0
