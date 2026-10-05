#requires -Version 7.0
param(
  [Parameter(Mandatory=$true)][string]$Executable,
  [Parameter(Mandatory=$true)][string]$Output,
  [Parameter(Mandatory=$true)][string]$BuildId,
  [Parameter(Mandatory=$true)][string]$RoundId,
  [Parameter(Mandatory=$true)][string]$PayloadManifest,
  [Parameter(Mandatory=$true)][ValidatePattern('^[a-f0-9]{64}$')][string]$ConfigurationSha256,
  [string]$Python=(Get-Command python.exe -ErrorAction Stop).Source,
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
$qaRoot=Assert-WorkspacePath -Workspace $workspace -Path (Join-Path $workspace '.qa')
if(!$exe.StartsWith($qaRoot+'\',[StringComparison]::OrdinalIgnoreCase)) {
  throw 'Cold-start measurement requires a complete installed QA copy inside .qa.'
}
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
$fixtureRunId=[Guid]::NewGuid().ToString('N')

function New-StartupFixture {
  param([string]$QaRoot,[string]$Executable,[string]$RunId,[int]$Sample)
  if($RunId -cnotmatch '^[a-f0-9]{32}$' -or $Sample -lt 0 -or $Sample -gt 99) { throw 'Invalid cold-start fixture identity.' }
  $ownedQa=Assert-NoReparsePath -Path $QaRoot
  $ownedExecutable=Assert-WorkspacePath -Workspace $ownedQa -Path $Executable -PathType File
  if([IO.Path]::GetFileName($ownedQa) -ine '.qa') { throw 'Cold-start fixtures require a .qa root.' }
  $run=Join-Path $ownedQa ('startup-'+$RunId)
  if(Test-Path -LiteralPath $run) { $run=Assert-WorkspacePath -Workspace $ownedQa -Path $run }
  else { New-Item -ItemType Directory -Path $run | Out-Null }
  $directory=Join-Path $run ('sample-'+$Sample.ToString('00'))
  if(Test-Path -LiteralPath $directory) { throw 'Cold-start sample directory already exists.' }
  New-Item -ItemType Directory -Path $directory | Out-Null
  $directory=Assert-WorkspacePath -Workspace $ownedQa -Path $directory
  $database=Join-Path $directory 'jianzhang.sqlite'
  $marker=Join-Path $directory 'startup-fixture.json'
  $configuration=[ordered]@{schemaVersion=1;purpose='jianzhang-windows-cold-start';runId=$RunId;sample=$Sample;databasePath=$database;executablePath=$ownedExecutable;initialTransactions=0;initialDatabaseExists=$false}
  $configuration | ConvertTo-Json | Set-Content -LiteralPath $marker -Encoding utf8NoBOM
  return [pscustomobject]@{databasePath=$database;directory=$directory;marker=$marker;runId=$RunId;sample=$Sample;argument=('--jianzhang-qa-database='+$database);initialTransactions=0;initialDatabaseExists=$false}
}

function Read-StartupDatabase {
  param([string]$Database,[string]$PythonExecutable)
  $db=Assert-NoReparsePath -Path $Database -PathType File
  $readOnly=@'
import json,pathlib,sqlite3,sys
with sqlite3.connect(pathlib.Path(sys.argv[1]).as_uri()+'?mode=ro',uri=True) as c:
    integrity=c.execute('pragma integrity_check').fetchall()
    active=c.execute("select value from app_meta where key='active'").fetchall()
    workspaces=c.execute('select key,sequence from workspaces order by key').fetchall()
    entries=c.execute('select count(*) from entries').fetchone()[0]
    version=c.execute('pragma user_version').fetchone()[0]
    if integrity != [('ok',)] or active != [('guest',)] or workspaces != [('guest',0)] or entries != 0 or version != 1:
        raise RuntimeError('Cold-start fixture is not an intact empty guest ledger')
    print(json.dumps({'integrity':'ok','activeWorkspace':'guest','workspaces':1,'sequence':0,'transactions':entries,'schemaVersion':version}))
'@
  $result=& $PythonExecutable -c $readOnly $db
  if($LASTEXITCODE -ne 0) { throw 'Read-only cold-start SQLite verification failed.' }
  return ($result -join "`n") | ConvertFrom-Json
}

function Wait-StartupMainWindow {
  param($Process,[Diagnostics.Stopwatch]$Clock,[Collections.Generic.List[object]]$Observations,[ValidateRange(1,15000)][int]$TimeoutMs=15000)
  if(!$Clock.IsRunning) { throw 'Startup clock must still be running before visible-window readiness.' }
  # MainWindowHandle is the visible top-level window of this Process. Refresh
  # invalidates cached handles; never search for or close another process's UI.
  while($Clock.ElapsedMilliseconds -lt $TimeoutMs) {
    if($Process.HasExited) { throw 'Native app exited before its visible main window.' }
    $Process.Refresh()
    $handle=$Process.MainWindowHandle.ToInt64()
    $Observations.Add(@{atMs=$Clock.Elapsed.TotalMilliseconds;mainWindowHandle=$handle})
    if($handle -ne 0) {
      # Called only after the post-ledger renderer marker. External startup time
      # ends when both the rendered ledger and visible main window are ready.
      $Clock.Stop()
      if($Clock.Elapsed.TotalMilliseconds -ge $TimeoutMs) {
        throw 'Native visible main window timed out within the total startup deadline.'
      }
      return @{mainWindowHandle=$handle;visibleAtMs=$Clock.Elapsed.TotalMilliseconds}
    }
    Start-Sleep -Milliseconds ([Math]::Min(10,[Math]::Max(1,$TimeoutMs-$Clock.ElapsedMilliseconds)))
  }
  throw 'Native visible main window timed out within the total startup deadline.'
}

function Write-StartupFailure {
  param([string]$QaRoot,[string]$Path,$Evidence)
  $owned=Assert-WorkspacePath -Workspace $QaRoot -Path $Path -PathType File -AllowMissing
  if(Test-Path -LiteralPath $owned) { throw 'Startup diagnostic already exists.' }
  $Evidence | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $owned -Encoding utf8NoBOM
  return $owned
}

for($sample=0;$sample -lt $Count;$sample++) {
  $fixture=New-StartupFixture -QaRoot $qaRoot -Executable $exe -RunId $fixtureRunId -Sample $sample
  $startInfo=[Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName=$exe
  $startInfo.ArgumentList.Add($fixture.argument)
  $startInfo.WorkingDirectory=[IO.Path]::GetDirectoryName($exe)
  $startInfo.UseShellExecute=$false
  $startInfo.RedirectStandardOutput=$true
  $startInfo.RedirectStandardError=$true
  $startInfo.CreateNoWindow=$true
  # This is the measured interactive GUI, which must actually be displayed.
  # CreateNoWindow suppresses a console without hiding the client window.
  $startInfo.WindowStyle=[Diagnostics.ProcessWindowStyle]::Normal
  $process=[Diagnostics.Process]::new()
  $started=$false
  $process.StartInfo=$startInfo
  $lines=[Collections.Generic.List[string]]::new()
  $windowObservations=[Collections.Generic.List[object]]::new()
  $sampleFailure=$null
  $stderr=$null
  $ready=$null
  $observedFixture=$null
  $visibleWindow=$null
  $closeAccepted=$false
  $sampleStartedAt=[DateTimeOffset]::UtcNow.ToString('o')
  $clock=[Diagnostics.Stopwatch]::StartNew()
  try {
    if(!$process.Start()) { throw 'Could not start native app.' }
    $started=$true
    $stderr=$process.StandardError.ReadToEndAsync()
    while($clock.ElapsedMilliseconds -lt 15000) {
      $read=$process.StandardOutput.ReadLineAsync()
      $remaining=[Math]::Max(1,15000-$clock.ElapsedMilliseconds)
      if(!$read.Wait([int]$remaining)) { throw 'Native rendered-home readiness timed out.' }
      $line=$read.Result
      if($null -eq $line) { throw 'Native app exited without rendered-home readiness.' }
      $lines.Add($line)
      if($line.StartsWith('JIANZHANG_QA_DATABASE ')) {
        if($observedFixture) { throw 'Duplicate QA database selection marker.' }
        $observedFixture=$line.Substring('JIANZHANG_QA_DATABASE '.Length) | ConvertFrom-Json
        if($observedFixture.databasePath -ine $fixture.databasePath -or $observedFixture.runId -cne $fixture.runId -or
           $observedFixture.sample -ne $sample -or $observedFixture.initialTransactions -ne 0) { throw 'Native QA database selection differs from this sample.' }
      }
      if($line.StartsWith('JIANZHANG_READY ')) {
        $ready=$line.Substring(16) | ConvertFrom-Json
        break
      }
    }
    if(!$observedFixture -or !$ready -or $ready.rendererFirstFrame -ne $true -or ($ready.readyMs -isnot [long] -and $ready.readyMs -isnot [int]) -or $ready.readyMs -lt 0) {
      throw 'Readiness must confirm the native renderer after ledger load.'
    }
    $visibleWindow=Wait-StartupMainWindow -Process $process -Clock $clock -Observations $windowObservations
    $elapsed=$clock.Elapsed.TotalMilliseconds
    $closeAccepted=$process.CloseMainWindow()
    if(!$closeAccepted) { throw 'Native app did not expose a closeable main window.' }
    if(!$process.WaitForExit(5000)) { throw 'Native app failed to close cleanly.' }
    if($process.ExitCode -ne 0) { throw "Native app exited with $($process.ExitCode)." }
    $databaseState=Read-StartupDatabase -Database $fixture.databasePath -PythonExecutable $Python
    $samples.Add($elapsed)
    $nativeSamples.Add([int]$ready.readyMs)
    $logs.Add(@{index=$sample;pid=$process.Id;externalMs=$elapsed;nativeMs=$ready.readyMs;stdout=$lines.ToArray();arguments=@($fixture.argument);fixture=$fixture;visibleWindow=$visibleWindow;windowObservations=$windowObservations.ToArray();closeAccepted=$closeAccepted;databaseAfterClose=$databaseState})
  } catch {
    $sampleFailure=$_
    throw
  } finally {
    # Only this measurement's child may be terminated on a failed run.
    $childKilled=$false
    $cleanupError=$null
    try {
      if($started -and !$process.HasExited) {
        $process.Kill()
        $childKilled=$true
        if(!$process.WaitForExit(5000)) { $cleanupError='Owned child did not exit after Kill.' }
      }
    } catch { $cleanupError=$_.Exception.ToString() }
    if($sampleFailure) {
      $clock.Stop()
      $stderrText=$null
      $stderrReadError=$null
      try { if($stderr -and $stderr.IsCompleted){$stderrText=$stderr.GetAwaiter().GetResult()} }
      catch { $stderrReadError=$_.Exception.ToString() }
      $diagnostic=Join-Path ([IO.Path]::GetDirectoryName($outputFile)) ([IO.Path]::GetFileNameWithoutExtension($outputFile)+'-failure-'+$fixtureRunId+'-'+$sample.ToString('00')+'.json')
      $failureEvidence=@{schemaVersion=1;status='failed';metric='windowsColdStartP95Ms';buildId=$BuildId;roundId=$RoundId;configurationSha256=$ConfigurationSha256;sampleIndex=$sample;startedAt=$sampleStartedAt;endedAt=[DateTimeOffset]::UtcNow.ToString('o');elapsedMs=$clock.Elapsed.TotalMilliseconds;acceptedSamples=$samples.ToArray();acceptedLaunches=$logs.ToArray();pid=$(if($started){$process.Id}else{$null});arguments=@($fixture.argument);fixture=$fixture;stdout=$lines.ToArray();stderr=$stderrText;stderrReadError=$stderrReadError;observedFixture=$observedFixture;ready=$ready;visibleWindow=$visibleWindow;windowObservations=$windowObservations.ToArray();closeAccepted=$closeAccepted;childKilled=$childKilled;cleanupError=$cleanupError;exception=$sampleFailure.Exception.ToString();stack=$sampleFailure.ScriptStackTrace;position=$sampleFailure.InvocationInfo.PositionMessage;executable=$exe;sha256=$hash;payloadSha256=$delivery.payload.sha256;installerSha256=$delivery.sha256;payloadManifestSha256=$payloadManifestHash}
      try {
        $written=Write-StartupFailure -QaRoot $qaRoot -Path $diagnostic -Evidence $failureEvidence
        [Console]::Error.WriteLine("Failed startup diagnostic: $written")
      } catch {
        # Preserve the original measurement failure if diagnostic storage fails.
        [Console]::Error.WriteLine("Startup diagnostic could not be saved: $($_.Exception.Message)")
      }
    }
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
@{metric='windowsColdStartP95Ms';roundId=$RoundId;buildId=$BuildId;mode='release';configurationSha256=$ConfigurationSha256;sampleCount=$Count;p95Ms=$p95;samples=$samples.ToArray();nativeSamples=$nativeSamples.ToArray();executable=$exe;sha256=$hash;payloadSha256=$delivery.payload.sha256;installerSha256=$delivery.sha256;payloadManifestSha256=$payloadManifestHash;method='fresh process launch with a new 0-transaction owned QA fixture; requires both native post-ledger rendered-frame marker and visible main window; no OS cache purge';dataState='fresh-empty-guest-ledger';fixtureRunId=$fixtureRunId;launches=$logs.ToArray()} |
  ConvertTo-Json -Depth 9 | Set-Content -LiteralPath $outputFile -Encoding utf8
Write-Host "Windows fresh-process startup p95: $p95 ms ($Count samples)."
$global:LASTEXITCODE=0
