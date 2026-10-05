$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'source-contract.ps1')
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$fixture=Join-Path $workspace ('.qa/build-paths-'+[Guid]::NewGuid().ToString('N'))
Assert-WorkspacePath -Workspace $workspace -Path $fixture -AllowMissing | Out-Null
New-Item -ItemType Directory -Path $fixture | Out-Null
$links=[Collections.Generic.List[string]]::new()
$results=[Collections.Generic.List[object]]::new()
function Check-Rejected {
  param([string]$Name,[scriptblock]$Action,[string]$ErrorPattern)
  $rejected=$false
  try { $accepted=& $Action } catch {
    if($_.Exception.Message -notmatch $ErrorPattern) { throw }
    $rejected=$true
  }
  if(!$rejected) { throw "Expected rejection: $Name (accepted: $accepted)" }
  $results.Add([pscustomobject]@{name=$Name;passed=$true})
}
function Make-Junction {
  param([string]$Path,[string]$Target)
  Assert-WorkspacePath -Workspace $fixture -Path $Path -AllowMissing | Out-Null
  New-Item -ItemType Junction -Path $Path -Target $Target | Out-Null
  $links.Add($Path)
}
try {
  $target=Join-Path $fixture 'untouched'
  New-Item -ItemType Directory -Path (Join-Path $target 'lib') | Out-Null
  $valuable=Join-Path $target 'lib/valuable.txt'
  [IO.File]::WriteAllText($valuable,'Keep this owned fixture intact.')
  $before=(Get-FileHash -LiteralPath $valuable -Algorithm SHA256).Hash

  $rootLink=Join-Path $fixture 'android-build-client'
  Make-Junction -Path $rootLink -Target $target
  Check-Rejected 'Android snapshot root junction' { Assert-WorkspacePath -Workspace $fixture -Path $rootLink -AllowMissing } 'reparse point'
  Check-Rejected 'Tree root junction' { Get-TreeFiles -Root $rootLink } 'reparse point'
  Check-Rejected 'Existing child below root junction' { Assert-WorkspacePath -Workspace $fixture -Path (Join-Path $rootLink 'lib') } 'reparse point'
  Check-Rejected 'Missing child below root junction' { Assert-WorkspacePath -Workspace $fixture -Path (Join-Path $rootLink 'new/directory') -AllowMissing } 'reparse point'

  $ancestorLink=Join-Path $fixture 'linked-tools'
  Make-Junction -Path $ancestorLink -Target $target
  Check-Rejected 'Windows snapshot ancestor junction' { Assert-WorkspacePath -Workspace $fixture -Path (Join-Path $ancestorLink 'windows-build-client') -AllowMissing } 'reparse point'
  Check-Rejected 'Tree ancestor junction' { Get-TreeFiles -Root (Join-Path $ancestorLink 'lib') } 'reparse point'

  $wrongType=Join-Path $fixture 'snapshot-file'
  [IO.File]::WriteAllText($wrongType,'Not a build directory.')
  Check-Rejected 'Snapshot root is a file' { Assert-WorkspacePath -Workspace $fixture -Path $wrongType -AllowMissing } 'wrong type'
  Check-Rejected 'Ancestor is a file' { Assert-WorkspacePath -Workspace $fixture -Path (Join-Path $wrongType 'child') -AllowMissing } 'wrong type'
  Check-Rejected 'Output file is a directory' { Assert-WorkspacePath -Workspace $fixture -Path $target -PathType File -AllowMissing } 'wrong type'
  Check-Rejected 'Normalized parent escape' { Assert-WorkspacePath -Workspace $fixture -Path (Join-Path $fixture '../outside') -AllowMissing } 'outside'
  Check-Rejected 'Workspace prefix sibling escape' { Assert-WorkspacePath -Workspace $fixture -Path ($fixture+'-sibling/new') -AllowMissing } 'outside'
  Assert-WorkspacePath -Workspace $fixture -Path (Join-Path $fixture 'ordinary/missing/build-client') -AllowMissing | Out-Null
  $results.Add([pscustomobject]@{name='Ordinary missing descendants accepted';passed=$true})
  if((Get-FileHash -LiteralPath $valuable -Algorithm SHA256).Hash -ne $before) { throw 'Junction rejection changed the target file.' }

  $client=Join-Path $fixture 'client'
  $java=Join-Path $client 'android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java'
  $activity=Join-Path $client 'android/app/src/main/kotlin/com/example/MainActivity.kt'
  foreach($path in @($java,$activity,(Join-Path $client '.dart_tool/package_config.json'),(Join-Path $client '.dart_tool/package_graph.json'))) {
    New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($path)) | Out-Null
  }
  [IO.File]::WriteAllText($java,'dev.flutter.plugins.integration_test.IntegrationTestPlugin')
  [IO.File]::WriteAllText($activity,'class MainActivity')
  [IO.File]::WriteAllText((Join-Path $client 'pubspec.yaml'),'version: 2.0.0+3')
  [IO.File]::WriteAllText((Join-Path $client 'pubspec.lock'),'immutable locked dependencies')
  foreach($metadata in @('.dart_tool/package_config.json','.dart_tool/package_graph.json','.flutter-plugins-dependencies')) { [IO.File]::WriteAllText((Join-Path $client $metadata),'{}') }
  $source=Get-ClientSourceContract -Root $client -Platform android
  $generated=Get-AndroidMetadataContract -Root $client -IncludeRegistrant
  if($source.files.path -contains 'android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java' -or $source.files.path -contains '.dart_tool/package_config.json') { throw 'Generated Android inputs leaked into handwritten source contract.' }
  [IO.File]::WriteAllText($java,'proper production plugin registrant')
  [IO.File]::WriteAllText((Join-Path $client '.dart_tool/package_config.json'),'{"regenerated":true}')
  Assert-FileContract $source (Get-ClientSourceContract -Root $client -Platform android) 'Unchanged handwritten inputs'
  if((Get-AndroidMetadataContract -Root $client -IncludeRegistrant).sha256 -eq $generated.sha256) { throw 'Generated input changes were not independently hashed.' }
  $results.Add([pscustomobject]@{name='Generated registrant and metadata have independent hashes';passed=$true})
  [IO.File]::WriteAllText($activity,'changed handwritten activity')
  Check-Rejected 'Handwritten activity change' { Assert-FileContract $source (Get-ClientSourceContract -Root $client -Platform android) 'Handwritten inputs' } 'differs'
  [IO.File]::WriteAllText($activity,'class MainActivity')
  [IO.File]::WriteAllText((Join-Path $client 'pubspec.lock'),'changed dependency lock')
  Check-Rejected 'Dependency lock change' { Assert-FileContract $source (Get-ClientSourceContract -Root $client -Platform android) 'Locked dependencies' } 'differs'

  $pluginRoot=Join-Path $client 'windows/flutter/ephemeral/.plugin_symlinks'
  New-Item -ItemType Directory -Path $pluginRoot | Out-Null
  Make-Junction -Path (Join-Path $pluginRoot 'owned_test_plugin') -Target $target
  Get-ClientSourceContract -Root $client -Platform windows | Out-Null
  $results.Add([pscustomobject]@{name='Excluded Windows plugin junction remains permitted';passed=$true})
  $evidence=Join-Path $workspace '.qa/build-path-verification.json'
  Assert-WorkspacePath -Workspace $workspace -Path $evidence -PathType File -AllowMissing | Out-Null
  @{checkedAt=[DateTime]::UtcNow.ToString('o');fixture=$fixture;targetUnchanged=$true;tests=@($results.ToArray())} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $evidence -Encoding utf8
  Write-Host "Build path/source contract checks: $($results.Count) passed."
} finally {
  # Only unlink junctions this test created. Verify every ancestor first, and
  # never recurse through a junction, even during failed-test cleanup.
  foreach($link in $links) {
    Assert-WorkspacePath -Workspace $workspace -Path ([IO.Path]::GetDirectoryName($link)) | Out-Null
    $item=Get-Item -LiteralPath $link -Force
    if(!($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Test junction was replaced unexpectedly: $link" }
    [IO.Directory]::Delete($link,$false)
  }
  Assert-WorkspacePath -Workspace $workspace -Path $fixture | Out-Null
  Get-TreeFiles -Root $fixture | Out-Null
  Remove-Item -LiteralPath $fixture -Recurse -Force
}
