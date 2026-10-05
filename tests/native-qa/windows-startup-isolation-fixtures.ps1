$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$helper=Join-Path $workspace 'scripts/native-toolchain/measure-windows-startup.ps1'
$errors=$null
$tokens=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($helper,[ref]$tokens,[ref]$errors)
if($errors.Count) { throw 'Cold-start measurement helper has parse errors.' }
. (Join-Path $workspace 'scripts/native-toolchain/source-contract.ps1')
$functions=$ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$true)
foreach($name in @('New-StartupFixture','Read-StartupDatabase')) {
  $definition=@($functions | Where-Object {$_.Name -eq $name})
  if($definition.Count -ne 1) { throw "Expected one helper: $name" }
  . ([scriptblock]::Create($definition[0].Extent.Text))
}
$resultRoot=Join-Path $workspace ('.qa/startup-isolation-pure-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $resultRoot | Out-Null
# The fixture's nested .qa is owned by this one test run; no production EXE runs.
$qa=Join-Path $resultRoot '.qa'
New-Item -ItemType Directory -Path $qa | Out-Null
$exe=Join-Path $qa 'payload 空格/jianzhang.exe'
New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($exe)) | Out-Null
Set-Content -LiteralPath $exe -Value 'not executed: startup helper fixture'
$python=(Get-Command python.exe -ErrorAction Stop).Source
$passed=[Collections.Generic.List[string]]::new()
function Assert([bool]$Condition,[string]$Message) { if(!$Condition) { throw $Message } }
function Must-Throw([scriptblock]$Action,[string]$Pattern) {
  $observed=$null
  try { & $Action | Out-Null } catch { $observed=$_.Exception.Message }
  Assert ($observed -and $observed -match $Pattern) "Expected failure: $Pattern"
}
function New-TestDatabase([string]$Path,[int]$Count=0,[string]$Workspace='guest',[int]$Sequence=0,[int]$Version=1) {
  $create=@'
import sqlite3,sys
with sqlite3.connect(sys.argv[1]) as c:
    c.executescript('create table app_meta(key text,value text);create table workspaces(key text,sequence integer);create table entries(id text);')
    c.execute('insert into app_meta values(?,?)',('active',sys.argv[3]))
    c.execute('insert into workspaces values(?,?)',(sys.argv[3],int(sys.argv[4])))
    c.executemany('insert into entries values(?)',[(str(i),) for i in range(int(sys.argv[2]))])
    c.execute('pragma user_version='+str(int(sys.argv[5])))
'@
  & $python -c $create $Path $Count $Workspace $Sequence $Version
  if($LASTEXITCODE -ne 0) { throw 'Could not create owned SQLite fixture.' }
}

$run=[Guid]::NewGuid().ToString('N')
$first=New-StartupFixture -QaRoot $qa -Executable $exe -RunId $run -Sample 0
$second=New-StartupFixture -QaRoot $qa -Executable $exe -RunId $run -Sample 1
$marker=Get-Content -LiteralPath $first.marker -Raw | ConvertFrom-Json
Assert ($first.databasePath -ne $second.databasePath -and !(Test-Path -LiteralPath $first.databasePath) -and !(Test-Path -LiteralPath $second.databasePath)) 'Each sample must have a distinct missing database.'
Assert ($marker.schemaVersion -eq 1 -and $marker.purpose -ceq 'jianzhang-windows-cold-start' -and $marker.runId -ceq $run -and $marker.sample -eq 0 -and $marker.initialTransactions -eq 0 -and $marker.initialDatabaseExists -eq $false -and $marker.executablePath -ceq $exe -and $marker.databasePath -ceq $first.databasePath) 'Fixture marker identity is incomplete.'
Assert ($first.argument -ceq ('--jianzhang-qa-database='+$first.databasePath)) 'Path must be forwarded as exactly one argument.'
Assert (@(Get-ChildItem -LiteralPath $first.directory -Force).Count -eq 1) 'Fresh fixture must only contain its marker.'
$passed.Add('two independent empty sample paths; exact executable/database/sample marker and one argument')

Must-Throw { New-StartupFixture -QaRoot $qa -Executable $exe -RunId $run -Sample 0 } 'already exists'
Assert ((Get-Content -LiteralPath $first.marker -Raw | ConvertFrom-Json).sample -eq 0) 'Repeated sample changed its marker.'
$passed.Add('existing sample cannot be reused or overwritten')

foreach($identity in @('bad','A'*32)) { Must-Throw { New-StartupFixture -QaRoot $qa -Executable $exe -RunId $identity -Sample 0 } 'identity' }
foreach($sample in @(-1,100)) { Must-Throw { New-StartupFixture -QaRoot $qa -Executable $exe -RunId $run -Sample $sample } 'identity' }
$passed.Add('invalid run IDs and sample ranges fail before creating fixtures')

Must-Throw { New-StartupFixture -QaRoot $resultRoot -Executable $exe -RunId ([Guid]::NewGuid().ToString('N')) -Sample 0 } '\.qa root'
$outside=Join-Path $resultRoot 'outside.exe'
Set-Content -LiteralPath $outside -Value 'retained outside marker'
Must-Throw { New-StartupFixture -QaRoot $qa -Executable $outside -RunId ([Guid]::NewGuid().ToString('N')) -Sample 0 } 'outside'
Assert ((Get-Content -LiteralPath $outside -Raw).Trim() -ceq 'retained outside marker') 'Outside marker was modified.'
$passed.Add('non-.qa root and outside executable rejected without modifying either')

$target=Join-Path $resultRoot 'junction-target'
New-Item -ItemType Directory -Path $target | Out-Null
$junction=Join-Path $qa ('startup-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Junction -Path $junction -Target $target | Out-Null
try {
  Must-Throw { New-StartupFixture -QaRoot $qa -Executable $exe -RunId ([IO.Path]::GetFileName($junction).Substring(8)) -Sample 0 } 'reparse'
  Assert (@(Get-ChildItem -LiteralPath $target -Force).Count -eq 0) 'Junction target was modified.'
} finally {
  # Nonrecursive removal of this specifically owned link, never its target.
  if((Get-Item -LiteralPath $junction -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { Remove-Item -LiteralPath $junction -Force }
}
$passed.Add('real owned junction rejected without touching its target')

New-TestDatabase -Path $first.databasePath
$hashBefore=(Get-FileHash -LiteralPath $first.databasePath -Algorithm SHA256).Hash
$state=Read-StartupDatabase -Database $first.databasePath -PythonExecutable $python
Assert ($state.transactions -eq 0 -and $state.activeWorkspace -ceq 'guest' -and $state.schemaVersion -eq 1 -and $state.sequence -eq 0 -and $state.integrity -ceq 'ok') 'Read-only empty guest verification is incomplete.'
Assert ((Get-FileHash -LiteralPath $first.databasePath -Algorithm SHA256).Hash -ceq $hashBefore) 'Read-only verification changed SQLite bytes.'
$passed.Add('actual read-only SQLite verification confirms intact empty guest without changing bytes')

foreach($condition in @('entries','workspace','sequence','version')) {
  $path=Join-Path $resultRoot ($condition+'.sqlite')
  switch($condition) {
    'entries' { New-TestDatabase -Path $path -Count 1 }
    'workspace' { New-TestDatabase -Path $path -Workspace 'cloud-account' }
    'sequence' { New-TestDatabase -Path $path -Sequence 1 }
    'version' { New-TestDatabase -Path $path -Version 99 }
  }
  Must-Throw { Read-StartupDatabase -Database $path -PythonExecutable $python } 'verification failed'
}
$passed.Add('nonempty ledger, wrong workspace, changed sequence and wrong schema rejected')

$corrupt=Join-Path $resultRoot 'corrupt.sqlite'
Set-Content -LiteralPath $corrupt -Value 'retained corrupt input'
Must-Throw { Read-StartupDatabase -Database $corrupt -PythonExecutable $python } 'verification failed'
Must-Throw { Read-StartupDatabase -Database (Join-Path $resultRoot 'missing.sqlite') -PythonExecutable $python } 'does not exist'
Assert ((Get-Content -LiteralPath $corrupt -Raw).Trim() -ceq 'retained corrupt input') 'Corrupt input was modified.'
Assert (!(Test-Path -LiteralPath (Join-Path $resultRoot 'missing.sqlite'))) 'Missing database was created.'
$passed.Add('corrupt or missing SQLite fails and is neither overwritten nor created')

# Readiness must be gated by the observed explicit path and verified post-close SQL.
$launches=$ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Read-StartupDatabase'},$true)
$arguments=$ast.FindAll({param($node) $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Extent.Text -eq '$startInfo.ArgumentList.Add($fixture.argument)'},$true)
Assert ($launches.Count -eq 1 -and $arguments.Count -eq 1) 'Measurement must select and verify each explicit database.'
Assert ($ast.Extent.Text.Contains('if(!$observedFixture -or !$ready') -and $ast.Extent.Text.Contains("dataState='fresh-empty-guest-ledger'")) 'Raw evidence must identify the selected empty fixture.'
Assert ($ast.Extent.Text.Contains('Assert-MeasurementPayload') -and $ast.Extent.Text.Contains("'Measured release sources after sampling'")) 'Source/payload guards must remain in place.'
$passed.Add('per-sample argument forwarding, selected path, SQL verification and provenance guards retained')

# Execute the real readiness IfStatement condition, never a copied expression.
$readinessIf=@($ast.FindAll({param($node)
  $node -is [Management.Automation.Language.IfStatementAst] -and
  $node.Extent.Text.Contains("throw 'Readiness must confirm the native renderer after ledger load.'")
},$true))
Assert ($readinessIf.Count -eq 1 -and $readinessIf[0].Clauses.Count -eq 1) 'Expected exactly one readiness rejection condition.'
$readinessCondition=$readinessIf[0].Clauses[0].Item1.Extent.Text
$rejectReadiness=[scriptblock]::Create('param($observedFixture,$ready) '+$readinessCondition)
$readinessCases=[Collections.Generic.List[object]]::new()
function Test-ReadinessCase([string]$Name,$Observed,$Ready,[bool]$ExpectedRejected) {
  $actual=[bool](& $rejectReadiness $Observed $Ready)
  $value=if($null -eq $Ready) { $null } else { $Ready.readyMs }
  $readinessCases.Add([ordered]@{name=$Name;selectionExists=($null -ne $Observed);readyExists=($null -ne $Ready);rendererFirstFrame=$Ready.rendererFirstFrame;readyMs=$value;readyMsType=$(if($null -eq $value){'null'}else{$value.GetType().FullName});expectedRejected=$ExpectedRejected;actualRejected=$actual;passed=($actual -eq $ExpectedRejected)})
}
$selection=[pscustomobject]@{databasePath=$first.databasePath}
foreach($duration in @([int]12,[long]12)) {
  $type=$duration.GetType().Name
  Test-ReadinessCase "missing selection $type" $null ([pscustomobject]@{rendererFirstFrame=$true;readyMs=$duration}) $true
  Test-ReadinessCase "false renderer $type" $selection ([pscustomobject]@{rendererFirstFrame=$false;readyMs=$duration}) $true
  Test-ReadinessCase "missing renderer $type" $selection ([pscustomobject]@{readyMs=$duration}) $true
  Test-ReadinessCase "valid readiness $type" $selection ([pscustomobject]@{rendererFirstFrame=$true;readyMs=$duration}) $false
}
Test-ReadinessCase 'missing ready' $selection $null $true
Test-ReadinessCase 'missing selection and ready' $null $null $true
foreach($duration in @([double]12.0,'12',[int]-1,[long]-1)) {
  Test-ReadinessCase ('invalid duration '+$duration.GetType().Name+' '+$duration) $selection ([pscustomobject]@{rendererFirstFrame=$true;readyMs=$duration}) $true
}
foreach($duration in @([int]0,[long]0)) {
  Test-ReadinessCase ('valid zero '+$duration.GetType().Name) $selection ([pscustomobject]@{rendererFirstFrame=$true;readyMs=$duration}) $false
}
$parsedReady='{"rendererFirstFrame":true,"readyMs":12}' | ConvertFrom-Json
Test-ReadinessCase 'missing selection actual JSON parser' $null $parsedReady $true
Test-ReadinessCase 'valid actual JSON parser' $selection $parsedReady $false
$readinessFailures=@($readinessCases | Where-Object {!$_.passed})
@{schemaVersion=1;actualAstCondition=$readinessCondition;cases=$readinessCases.ToArray();failedCases=$readinessFailures.Count;productionExecutableLaunched=$false;helperSha256=(Get-FileHash -LiteralPath $helper -Algorithm SHA256).Hash.ToLowerInvariant()} |
  ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $resultRoot 'readiness-cases.json') -Encoding utf8
Assert ($readinessFailures.Count -eq 0) "Readiness AST rejected/accepted incorrectly in $($readinessFailures.Count) cases; evidence: $resultRoot"
$passed.Add("actual readiness IfStatement AST: $($readinessCases.Count) int/long/JSON positive and negative scenarios passed")

$windowStyleAst=@($ast.FindAll({param($node)
  $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$startInfo.WindowStyle'
},$true))
Assert ($windowStyleAst.Count -eq 1) 'Expected one actual measured GUI window style.'
$actualWindowStyle=& ([scriptblock]::Create($windowStyleAst[0].Right.Extent.Text))
@{schemaVersion=1;actualAst=$windowStyleAst[0].Extent.Text;actualWindowStyle=$actualWindowStyle.ToString();expectedWindowStyle='Normal';passed=($actualWindowStyle -eq [Diagnostics.ProcessWindowStyle]::Normal);productionExecutableLaunched=$false} |
  ConvertTo-Json | Set-Content -LiteralPath (Join-Path $resultRoot 'window-style.json') -Encoding utf8
Assert ($actualWindowStyle -eq [Diagnostics.ProcessWindowStyle]::Normal) "Measured client must display its interactive window; actual AST config is $actualWindowStyle; evidence: $resultRoot"
$passed.Add('actual StartInfo AST config displays the interactive client instead of hiding it')

foreach($name in @('Wait-StartupMainWindow','Write-StartupFailure')) {
  $definition=@($functions | Where-Object {$_.Name -eq $name})
  if($definition.Count -ne 1) { throw "Expected one helper: $name" }
  . ([scriptblock]::Create($definition[0].Extent.Text))
}

# Execute only actual StartInfo assignments and ArgumentList.Add, never Start().
$fixture=$first
$startInfoAssignments=$ast.FindAll({param($node)
  $node -is [Management.Automation.Language.AssignmentStatementAst] -and
  ($node.Left.Extent.Text -eq '$startInfo' -or $node.Left.Extent.Text.StartsWith('$startInfo.'))
},$true)
foreach($assignment in $startInfoAssignments) { . ([scriptblock]::Create($assignment.Extent.Text)) }
. ([scriptblock]::Create($arguments[0].Extent.Text))
Assert ($startInfo.WindowStyle -eq [Diagnostics.ProcessWindowStyle]::Normal -and $startInfo.CreateNoWindow -and !$startInfo.UseShellExecute -and $startInfo.RedirectStandardOutput -and $startInfo.RedirectStandardError) 'Measured GUI launch must be visible while capturing stdout/stderr without a console.'
Assert ($startInfo.FileName -ceq $exe -and $startInfo.ArgumentList.Count -eq 1 -and $startInfo.ArgumentList[0] -ceq $first.argument) 'Actual launch assignments lost the owned executable or single exact fixture argument.'
$passed.Add('actual StartInfo assignments and argument call preserve visible GUI, no console and exact path')

function New-FakeProcess([int]$ReadyAfter=2,[bool]$Exited=$false) {
  $fake=[pscustomobject]@{HasExited=$Exited;MainWindowHandle=[IntPtr]::Zero;RefreshCount=0;ReadyAfter=$ReadyAfter}
  $fake | Add-Member -MemberType ScriptMethod -Name Refresh -Value {
    $this.RefreshCount++
    if($this.ReadyAfter -gt 0 -and $this.RefreshCount -ge $this.ReadyAfter) { $this.MainWindowHandle=[IntPtr]123 }
  }
  return $fake
}
$fake=New-FakeProcess
$observations=[Collections.Generic.List[object]]::new()
$watch=[Diagnostics.Stopwatch]::StartNew()
Start-Sleep -Milliseconds 2
$nativeMarkerAt=$watch.Elapsed.TotalMilliseconds
$visible=Wait-StartupMainWindow -Process $fake -Clock $watch -Observations $observations
Assert ($fake.RefreshCount -eq 2 -and $observations.Count -eq 2 -and $observations[0].mainWindowHandle -eq 0 -and $observations[1].mainWindowHandle -eq 123) 'Visible-window helper must refresh until the owned Process exposes a visible window.'
Assert (!$watch.IsRunning -and $visible.mainWindowHandle -eq 123 -and $visible.visibleAtMs -ge $nativeMarkerAt -and $visible.visibleAtMs -eq $watch.Elapsed.TotalMilliseconds) 'Timer must stop after both native readiness and visible window.'
$passed.Add('real window-wait helper refreshes delayed handle and stops timer after native-ready and visibility')

$watch=[Diagnostics.Stopwatch]::StartNew()
Must-Throw { Wait-StartupMainWindow -Process (New-FakeProcess -Exited $true) -Clock $watch -Observations ([Collections.Generic.List[object]]::new()) } 'exited before'
$watch.Stop()
$watch=[Diagnostics.Stopwatch]::StartNew()
Must-Throw { Wait-StartupMainWindow -Process (New-FakeProcess -ReadyAfter 0) -Clock $watch -Observations ([Collections.Generic.List[object]]::new()) -TimeoutMs 5 } 'total startup deadline'
$watch.Stop()
Assert ($watch.ElapsedMilliseconds -lt 1000) 'Never-visible window must fail within its bounded startup deadline.'
Must-Throw { Wait-StartupMainWindow -Process (New-FakeProcess) -Clock $watch -Observations ([Collections.Generic.List[object]]::new()) } 'must still be running'
$passed.Add('exited, never-visible or stopped-clock child cannot skip the visible-window requirement')

# Run the actual extracted helper with a Refresh that crosses the deadline.
$lateProcess=New-FakeProcess -ReadyAfter 1
$lateProcess | Add-Member -MemberType ScriptMethod -Name Refresh -Force -Value {
  $this.RefreshCount++
  Start-Sleep -Milliseconds 60
  $this.MainWindowHandle=[IntPtr]123
}
$lateObservations=[Collections.Generic.List[object]]::new()
$lateWatch=[Diagnostics.Stopwatch]::StartNew()
$lateAccepted=$false
$lateResult=$null
$lateError=$null
try {
  $lateResult=Wait-StartupMainWindow -Process $lateProcess -Clock $lateWatch -Observations $lateObservations -TimeoutMs 20
  $lateAccepted=$true
} catch { $lateError=$_.Exception.Message }
$lateWatch.Stop()
@{schemaVersion=1;timeoutMs=20;refreshDelayMs=60;refreshCalls=$lateProcess.RefreshCount;accepted=$lateAccepted;elapsedMs=$lateWatch.Elapsed.TotalMilliseconds;returned=$lateResult;error=$lateError;observations=$lateObservations.ToArray();helperSha256=(Get-FileHash -LiteralPath $helper -Algorithm SHA256).Hash.ToLowerInvariant();productionExecutableLaunched=$false} |
  ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $resultRoot 'late-refresh-deadline.json') -Encoding utf8
Assert ($lateProcess.RefreshCount -eq 1 -and $lateObservations.Count -eq 1 -and $lateObservations[0].mainWindowHandle -eq 123) 'Delayed Refresh regression must actually reach the late visible handle.'
Assert (!$lateAccepted -and $lateError -match 'total startup deadline') "Late visible handle must be rejected after Refresh crosses deadline; evidence: $resultRoot"
$passed.Add('actual window helper rejects a visible handle returned by Refresh after the total deadline')

$waitCalls=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Wait-StartupMainWindow'},$true))
$elapsedAst=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$elapsed'},$true))
$closeAst=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Extent.Text -eq '$process.CloseMainWindow()'},$true))
$sampleAdd=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Extent.Text -eq '$samples.Add($elapsed)'},$true))
Assert ($waitCalls.Count -eq 1 -and $elapsedAst.Count -eq 1 -and $closeAst.Count -eq 1 -and $sampleAdd.Count -eq 1) 'Expected unique visible-wait, external timer, close and sample acceptance steps.'
Assert ($waitCalls[0].Extent.StartOffset -gt $readinessIf[0].Extent.EndOffset -and $elapsedAst[0].Extent.StartOffset -gt $waitCalls[0].Extent.EndOffset -and $closeAst[0].Extent.StartOffset -gt $elapsedAst[0].Extent.EndOffset -and $sampleAdd[0].Extent.StartOffset -gt $launches[0].Extent.EndOffset) 'Actual AST order must require ready then visible, stop before close, and accept only after SQL validation.'
$passed.Add('actual measurement AST order gates ready/visibility, excludes close latency and delays sample acceptance until SQL')

$failurePath=Join-Path $resultRoot '.qa/owned-failure.json'
$failurePayload=@{schemaVersion=1;status='failed';pid=123;stdout=@('QA selected','renderer ready');fixture=$first;windowObservations=@(@{mainWindowHandle=0});exception='expected fixture failure';acceptedSamples=@()}
$written=Write-StartupFailure -QaRoot $qa -Path $failurePath -Evidence $failurePayload
$failureRead=Get-Content -LiteralPath $written -Raw | ConvertFrom-Json
Assert ($failureRead.status -ceq 'failed' -and $failureRead.pid -eq 123 -and $failureRead.stdout.Count -eq 2 -and $failureRead.windowObservations[0].mainWindowHandle -eq 0 -and $failureRead.acceptedSamples.Count -eq 0) 'Owned failure writer must preserve raw failed sampling information.'
$failureHash=(Get-FileHash -LiteralPath $failurePath -Algorithm SHA256).Hash
Must-Throw { Write-StartupFailure -QaRoot $qa -Path $failurePath -Evidence @{status='overwritten'} } 'already exists'
Must-Throw { Write-StartupFailure -QaRoot $qa -Path (Join-Path $resultRoot 'outside-failure.json') -Evidence $failurePayload } 'outside'
Assert ((Get-FileHash -LiteralPath $failurePath -Algorithm SHA256).Hash -ceq $failureHash -and !(Test-Path -LiteralPath (Join-Path $resultRoot 'outside-failure.json'))) 'Failure writer must neither overwrite earlier evidence nor create outside paths.'
$passed.Add('actual owned failure writer preserves diagnostics and rejects overwrite or outside output')

@{schemaVersion=1;passed=$passed.ToArray();count=$passed.Count;productionExecutableLaunched=$false;resultRoot=$resultRoot;helperSha256=(Get-FileHash -LiteralPath $helper -Algorithm SHA256).Hash.ToLowerInvariant()} |
  ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $resultRoot 'evidence.json') -Encoding utf8
Write-Host "Windows startup isolation helper fixtures: $($passed.Count) passed; evidence: $resultRoot"
$global:LASTEXITCODE=0
