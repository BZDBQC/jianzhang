param([string]$EvidenceRoot)
$ErrorActionPreference = 'Stop'
if($env:OS -ne 'Windows_NT') { throw 'Package publication fixtures require Windows.' }
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$source = Join-Path $workspace 'scripts/package-windows-client.ps1'
$sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count) { throw 'Packaging script could not be parsed.' }
$statements = @($ast.FindAll({param($node)
  $node -is [Management.Automation.Language.IfStatementAst] -and
  $node.Extent.Text -match '\[IO\.File\]::Replace\('
},$true))
if($statements.Count -ne 1) { throw 'Expected one production artifact publication statement.' }
# Execute the actual production statement, without invoking NSIS/build/install.
$publication = [scriptblock]::Create($statements[0].Extent.Text)
if(!$EvidenceRoot) { $EvidenceRoot = Join-Path $workspace ('.qa/package-publication-'+[Guid]::NewGuid().ToString('N')) }
$EvidenceRoot = [IO.Path]::GetFullPath($EvidenceRoot)
if(!$EvidenceRoot.StartsWith((Join-Path $workspace '.qa')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) {
  throw 'Publication evidence must be a fresh directory inside workspace .qa.'
}
if(Test-Path -LiteralPath $EvidenceRoot) { throw 'Publication evidence directory already exists.' }
$ancestor = [IO.Path]::GetDirectoryName($EvidenceRoot)
while($ancestor -and $ancestor -ne $workspace) {
  if(Test-Path -LiteralPath $ancestor) {
    if((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
      throw 'Publication evidence cannot traverse reparse points.'
    }
  }
  $ancestor = [IO.Path]::GetDirectoryName($ancestor)
}
New-Item -ItemType Directory -Path $EvidenceRoot | Out-Null
$results = [Collections.Generic.List[object]]::new()
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Assert-Same([string]$Path,[string]$Expected,[string]$Label) {
  if(!(Test-Path -LiteralPath $Path -PathType Leaf) -or (Hash $Path) -ne $Expected) { throw "$Label bytes changed or disappeared." }
}
function Invoke-Publication($Scenario) {
  $candidate = $Scenario.candidate
  $Output = $Scenario.output
  & $publication
}
function New-Scenario([string]$Name,[bool]$Existing=$true) {
  $root = Join-Path $EvidenceRoot $Name
  New-Item -ItemType Directory -Path $root | Out-Null
  $candidate = Join-Path $root 'candidate-简账.exe'
  $outputFile = Join-Path $root 'existing-简账.exe'
  $manifest = $outputFile+'.manifest.json'
  [IO.File]::WriteAllText($candidate,('完整候选🙂'+('payload-'*512)))
  if($Existing) { [IO.File]::WriteAllText($outputFile,('完整旧安装包🙂'+('old-'*512))) }
  [IO.File]::WriteAllText($manifest,'{"status":"old-complete-manifest"}')
  [pscustomobject]@{candidate=$candidate;output=$outputFile;manifest=$manifest;candidateHash=(Hash $candidate);oldHash=$(if($Existing){Hash $outputFile}else{''});manifestHash=(Hash $manifest)}
}
function Assert-Published($Scenario,[string]$Name) {
  Assert-Same $Scenario.output $Scenario.candidateHash $Name
  Assert-Same $Scenario.manifest $Scenario.manifestHash "$Name existing sidecar"
  if(Test-Path -LiteralPath $Scenario.candidate) { throw "$Name did not consume the staged candidate." }
  if(@(Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($Scenario.output)) -File -Force).Count -ne 2) {
    throw "$Name left unexpected publication or backup files."
  }
  $results.Add([pscustomobject]@{name=$Name;passed=$true;outputHash=(Hash $Scenario.output);sidecarUnchanged=$true})
}
function Assert-Rejected($Scenario,[string]$Mode) {
  $handle = $null; $caught = $null
  $attributes = [IO.File]::GetAttributes($Scenario.output)
  try {
    switch($Mode) {
      'locked-output' { $handle=[IO.File]::Open($Scenario.output,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None) }
      'locked-candidate' { $handle=[IO.File]::Open($Scenario.candidate,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None) }
      'readonly-output' { [IO.File]::SetAttributes($Scenario.output,($attributes -bor [IO.FileAttributes]::ReadOnly)) }
      'missing-candidate' { [IO.File]::Delete($Scenario.candidate) }
      default { throw "Unknown publication failure fixture: $Mode" }
    }
    try { Invoke-Publication $Scenario } catch { $caught=$_.Exception }
  } finally {
    if($handle) { $handle.Dispose() }
    if($Mode -eq 'readonly-output') { [IO.File]::SetAttributes($Scenario.output,$attributes) }
  }
  if(!$caught) { throw "$Mode unexpectedly published." }
  while($caught.InnerException) { $caught=$caught.InnerException }
  Assert-Same $Scenario.output $Scenario.oldHash "$Mode prior installer"
  Assert-Same $Scenario.manifest $Scenario.manifestHash "$Mode prior manifest"
  if($Mode -ne 'missing-candidate') { Assert-Same $Scenario.candidate $Scenario.candidateHash "$Mode staged candidate" }
  $results.Add([pscustomobject]@{name=$Mode;passed=$true;exception=$caught.GetType().FullName;hresult=$caught.HResult;message=$caught.Message;oldInstallerUnchanged=$true;oldManifestUnchanged=$true})
}
$failed = $null
try {
  $fresh = New-Scenario 'first-publish' $false
  Invoke-Publication $fresh
  Assert-Published $fresh 'first-publish'
  $repeat = New-Scenario 'repeat-existing'
  for($iteration=1;$iteration -le 2;$iteration++) {
    if($iteration -gt 1) {
      [IO.File]::WriteAllText($repeat.candidate,('第二次完整候选🙂'+('new-'*1024)))
      $repeat.candidateHash = Hash $repeat.candidate
    }
    Invoke-Publication $repeat
    Assert-Published $repeat "replace-existing-$iteration"
  }
  foreach($mode in @('locked-output','locked-candidate','readonly-output','missing-candidate')) {
    $scenario = New-Scenario $mode
    Assert-Rejected $scenario $mode
    if($mode -ne 'missing-candidate') {
      Invoke-Publication $scenario
      Assert-Published $scenario "$mode-retry"
    }
  }
  if((Hash $source) -ne $sourceHash) { throw 'Production packaging source changed during fixtures.' }
} catch {
  $failed=$_.Exception
  while($failed.InnerException) { $failed=$failed.InnerException }
} finally {
  [pscustomobject]@{schemaVersion=1;passed=($null -eq $failed);source=$source;sourceSha256=$sourceHash;publication=$statements[0].Extent.Text;powershell=$PSVersionTable.PSVersion.ToString();dotnet=[Environment]::Version.ToString();evidenceRoot=$EvidenceRoot;tests=$results.ToArray();failure=$(if($failed){$failed.Message}else{$null});scope='File-only fixtures executing production publication statement; no build, NSIS, installer or registry operations'} |
    ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $EvidenceRoot 'evidence.json') -Encoding utf8
}
if($failed) { throw $failed }
Write-Host "Package publication fixtures: $($results.Count) passed. Evidence: $EvidenceRoot"
