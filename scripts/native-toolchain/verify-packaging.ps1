param([switch]$CompileInstaller)
$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $PSScriptRoot 'source-contract.ps1')
$fixture=Join-Path $workspace ('.qa/packaging-unit-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$passed=0
function Assert-Rejected([scriptblock]$Action,[string]$Name) {
  $rejected=$false
  try { & $Action } catch { $rejected=$true }
  if(!$rejected) { throw "Expected rejection: $Name" }
  $script:passed++
}
$syntaxIssues=@()
foreach($script in @((Get-ChildItem -LiteralPath $PSScriptRoot -Filter *.ps1).FullName)+(Join-Path $workspace 'scripts/package-windows-client.ps1')) {
  $tokens=$null;$issues=$null
  [Management.Automation.Language.Parser]::ParseFile($script,[ref]$tokens,[ref]$issues) | Out-Null
  $syntaxIssues += $issues
}
if($syntaxIssues.Count) { throw ($syntaxIssues | Out-String) }
$passed++
& (Join-Path $PSScriptRoot 'test-package-publication.ps1') -EvidenceRoot (Join-Path $fixture 'publication')
$passed++
$source=Join-Path $fixture 'source'
New-Item -ItemType Directory -Path (Join-Path $source 'lib'),(Join-Path $source 'assets'),(Join-Path $source 'windows') | Out-Null
'version: 2.0.0+3' | Set-Content -LiteralPath (Join-Path $source 'pubspec.yaml')
'original source' | Set-Content -LiteralPath (Join-Path $source 'lib/main.dart')
'original asset' | Set-Content -LiteralPath (Join-Path $source 'assets/icon.txt')
'project(jianzhang)' | Set-Content -LiteralPath (Join-Path $source 'windows/CMakeLists.txt')
$expected=Get-ClientSourceContract -Root $source -Platform windows
Assert-FileContract $expected (Get-ClientSourceContract -Root $source -Platform windows) 'Stable source'
$passed++
'changed asset' | Set-Content -LiteralPath (Join-Path $source 'assets/icon.txt')
Assert-Rejected {Assert-FileContract $expected (Get-ClientSourceContract -Root $source -Platform windows) 'Changed asset'} 'asset source change'
$payloadRoot=Join-Path $fixture 'payload'
New-Item -ItemType Directory -Path $payloadRoot | Out-Null
'binary fixture' | Set-Content -LiteralPath (Join-Path $payloadRoot 'fixture.txt')
$payload=Get-PayloadContract -Root $payloadRoot
Assert-FileContract $payload (Get-PayloadContract -Root $payloadRoot) 'Stable payload'
$passed++
'tampered' | Set-Content -LiteralPath (Join-Path $payloadRoot 'fixture.txt')
Assert-Rejected {Assert-FileContract $payload (Get-PayloadContract -Root $payloadRoot) 'Tampered payload'} 'payload tamper'
$pluginMetadata=Join-Path $fixture 'plugins.json'
'{"plugins":{"windows":[]}}' | Set-Content -LiteralPath $pluginMetadata
Assert-Rejected {Assert-WindowsPayload -Root $payloadRoot -PluginMetadata $pluginMetadata} 'missing native DLL'
# Verify the packaging failure branch restores the caller process environment.
$names=@('TEMP','TMP','NSISDIR','PUB_CACHE','APPDATA','LOCALAPPDATA','DASH__SUPPRESS_ANALYTICS','FLUTTER_SUPPRESS_ANALYTICS')
$before=@{}
foreach($name in $names) {$before[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
$oldManifest=Join-Path $fixture 'old-build.json'
'{"schemaVersion":1}' | Set-Content -LiteralPath $oldManifest
Assert-Rejected { & (Join-Path $workspace 'scripts/package-windows-client.ps1') -BuildManifest $oldManifest -Output (Join-Path $fixture 'must-not-exist.exe') } 'stale build manifest'
foreach($name in $names) {if([Environment]::GetEnvironmentVariable($name,'Process') -cne $before[$name]) {throw "Leaked process environment: $name"}}
if(Test-Path -LiteralPath (Join-Path $fixture 'must-not-exist.exe')) {throw 'Stale packaging produced an installer'}
$passed++
# Fake old/incomplete SDK entry: the verifier must inspect machine output.
$fakeSdk=Join-Path $fixture 'fake-flutter'
New-Item -ItemType Directory -Path (Join-Path $fakeSdk 'bin') | Out-Null
@('@echo off','echo {"frameworkVersion":"3.0.0","frameworkRevision":"old","channel":"stable","dartSdkVersion":"2.0.0"}','exit /b 0') | Set-Content -Encoding ascii -LiteralPath (Join-Path $fakeSdk 'bin/flutter.bat')
Assert-Rejected {Assert-FlutterVersion -FlutterRoot $fakeSdk -Release ([pscustomobject]@{version='3.47.6';hash='expected';channel='stable';dart_sdk_version='3.13.5'})} 'installed SDK mismatch'
$csc=Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
$helperSource=Join-Path $PSScriptRoot 'installer-transaction.cs'
$helper=Join-Path $fixture 'installer-transaction.exe'
& $csc /nologo /warnaserror+ /target:winexe /platform:x86 /optimize+ /reference:System.Web.Extensions.dll "/out:$helper" $helperSource
if($LASTEXITCODE -ne 0) {throw "Production helper compile failed: $LASTEXITCODE"}
$qaHelper=Join-Path $fixture 'installer-transaction-qa.exe'
& $csc /nologo /warnaserror+ /target:winexe /platform:x86 /optimize+ /define:INSTALLER_QA /reference:System.Web.Extensions.dll "/out:$qaHelper" $helperSource
if($LASTEXITCODE -ne 0) {throw "QA helper compile failed: $LASTEXITCODE"}
$fileTests=Join-Path $fixture 'file-tests.exe'
& $csc /nologo /warnaserror+ /target:exe /platform:x86 /optimize+ /define:INSTALLER_FILE_TESTS /reference:System.Web.Extensions.dll /main:JianzhangInstaller.FileTests "/out:$fileTests" $helperSource (Join-Path $PSScriptRoot 'installer-transaction-file-tests.cs')
if($LASTEXITCODE -ne 0) {throw "File-only harness compile failed: $LASTEXITCODE"}
& $fileTests (Join-Path $fixture 'file-tests')
if($LASTEXITCODE -ne 0) {throw "File-only tests failed: $LASTEXITCODE"}
$passed++
if($CompileInstaller) {
  # Syntax smoke only: never execute this fake-payload installer.
  'fixture payload' | Set-Content -LiteralPath (Join-Path $payloadRoot 'fixture.txt')
  $config=Join-Path $fixture 'transaction.json'
  @{version='2.0.0';qaRoot=$fixture;files=(Get-PayloadContract -Root $payloadRoot).files} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $config -Encoding utf8
  $checks=Join-Path $fixture 'checks.nsh';$deletions=Join-Path $fixture 'deletions.nsh'
  '!insertmacro CheckExistingFile "fixture.txt"' | Set-Content -LiteralPath $checks
  'Delete "$INSTDIR\fixture.txt"' | Set-Content -LiteralPath $deletions
  $compilerRoot=Join-Path $workspace '.tools/nsis-3.12/nsis-bundle/windows'
  $previousNsis=[Environment]::GetEnvironmentVariable('NSISDIR','Process')
  try {
    $env:NSISDIR=$compilerRoot
    & (Join-Path $compilerRoot 'makensis.exe') /V2 /DAPP_VERSION=2.0.0 "/DBUNDLE_DIR=$payloadRoot" "/DOUTPUT_FILE=$(Join-Path $fixture 'syntax-smoke.exe')" "/DQA_OUTPUT=$(Join-Path $fixture 'syntax-smoke.exe')" "/DQA_ROOT=$fixture" "/DAPP_ICON=$(Join-Path $workspace 'clients/flutter/packaging/windows/icon.ico')" "/DBUNDLE_CHECKS=$checks" "/DBUNDLE_DELETE=$deletions" "/DTX_HELPER=$qaHelper" "/DTX_CONFIG=$config" "/DTX_CONFIG_SHA256=$((Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash.ToLowerInvariant())" (Join-Path $workspace 'clients/flutter/packaging/windows/installer.nsi')
    if($LASTEXITCODE -ne 0) {throw "NSIS syntax compile failed: $LASTEXITCODE"}
    $passed++
    $productionConfig=Join-Path $fixture 'transaction-production.json'
    @{version='2.0.0';qaRoot=$null;files=(Get-PayloadContract -Root $payloadRoot).files} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $productionConfig -Encoding utf8
    & (Join-Path $compilerRoot 'makensis.exe') /V2 /DAPP_VERSION=2.0.0 "/DBUNDLE_DIR=$payloadRoot" "/DOUTPUT_FILE=$(Join-Path $fixture 'syntax-smoke-production.exe')" "/DAPP_ICON=$(Join-Path $workspace 'clients/flutter/packaging/windows/icon.ico')" "/DBUNDLE_CHECKS=$checks" "/DBUNDLE_DELETE=$deletions" "/DTX_HELPER=$helper" "/DTX_CONFIG=$productionConfig" "/DTX_CONFIG_SHA256=$((Get-FileHash -LiteralPath $productionConfig -Algorithm SHA256).Hash.ToLowerInvariant())" (Join-Path $workspace 'clients/flutter/packaging/windows/installer.nsi')
    if($LASTEXITCODE -ne 0) {throw "Production NSIS syntax compile failed: $LASTEXITCODE"}
    $passed++
  } finally {Restore-ProcessEnvironment @{NSISDIR=$previousNsis}}
}
Write-Host "PACKAGING_UNIT_TESTS passed=$passed fixture=$fixture; no installer execution or registry probe."
