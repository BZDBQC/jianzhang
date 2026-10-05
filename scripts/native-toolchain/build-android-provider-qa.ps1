param([string]$JavaHome='C:\Program Files\Java\jdk-17.0.3.1')
$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $PSScriptRoot 'source-contract.ps1')
$sourceRoot=Assert-WorkspacePath -Workspace $workspace -Path (Join-Path $PSScriptRoot 'android-provider-qa') -PathType Directory
$sourceContract=Get-FileListContract -Root $sourceRoot -Files @(Get-TreeFiles -Root $sourceRoot)
$fixture=Assert-WorkspacePath -Workspace $workspace -Path (Join-Path $workspace 'tests/fixtures/native-ledger-v1.json') -PathType File
$fixtureHash=(Get-FileHash -LiteralPath $fixture -Algorithm SHA256).Hash.ToLowerInvariant()
$sdk=Assert-WorkspacePath -Workspace $workspace -Path (Join-Path $workspace '.tools/android-sdk') -PathType Directory
$tools=Assert-WorkspacePath -Workspace $workspace -Path (Join-Path $sdk 'build-tools/36.0.0') -PathType Directory
$androidJar=Assert-WorkspacePath -Workspace $workspace -Path (Join-Path $sdk 'platforms/android-35/android.jar') -PathType File
$java=Assert-NoReparsePath -Path $JavaHome -PathType Directory
foreach($executable in @('javac.exe','jar.exe','keytool.exe')) { Assert-NoReparsePath -Path (Join-Path $java ('bin/'+$executable)) -PathType File | Out-Null }
$qa=Assert-WorkspacePath -Workspace $workspace -Path (Join-Path $workspace ('.qa/android-provider-build-'+[Guid]::NewGuid().ToString('N'))) -PathType Directory -AllowMissing
New-Item -ItemType Directory -Path $qa -ErrorAction Stop | Out-Null
$qa=Assert-WorkspacePath -Workspace $workspace -Path $qa -PathType Directory
foreach($child in @('assets','classes','dex')) { New-Item -ItemType Directory -Path (Join-Path $qa $child) -ErrorAction Stop | Out-Null }
$previousJavaHome=[Environment]::GetEnvironmentVariable('JAVA_HOME','Process')
try {
  $env:JAVA_HOME=$java
  Copy-Item -LiteralPath $fixture -Destination (Join-Path $qa 'assets/ledger.json')
  & (Join-Path $java 'bin/javac.exe') -encoding UTF-8 --release 8 -classpath $androidJar -d (Join-Path $qa 'classes') (Join-Path $sourceRoot 'FaultDocumentsProvider.java')
  if ($LASTEXITCODE -ne 0) { throw 'QA provider Java compilation failed.' }
  & (Join-Path $tools 'aapt.exe') package -f -M (Join-Path $sourceRoot 'AndroidManifest.xml') -I $androidJar -A (Join-Path $qa 'assets') -F (Join-Path $qa 'unsigned.apk')
  if ($LASTEXITCODE -ne 0) { throw 'QA provider aapt failed.' }
  & (Join-Path $tools 'd8.bat') --min-api 26 --lib $androidJar --output (Join-Path $qa 'dex') (Join-Path $qa 'classes/com/jianzhang/qa/faultprovider/FaultDocumentsProvider.class')
  if ($LASTEXITCODE -ne 0) { throw 'QA provider D8 failed.' }
  & (Join-Path $java 'bin/jar.exe') uf (Join-Path $qa 'unsigned.apk') -C (Join-Path $qa 'dex') classes.dex
  if ($LASTEXITCODE -ne 0) { throw 'QA provider dex packaging failed.' }
  & (Join-Path $tools 'zipalign.exe') -f 4 (Join-Path $qa 'unsigned.apk') (Join-Path $qa 'aligned.apk')
  if ($LASTEXITCODE -ne 0) { throw 'QA provider zipalign failed.' }
  $key=Join-Path $qa 'qa-debug.keystore'
  # This disposable QA-only package never uses or changes the client release key.
  & (Join-Path $java 'bin/keytool.exe') -genkeypair -keystore $key -alias qa -storepass android -keypass android -keyalg RSA -keysize 2048 -validity 10 -dname 'CN=Owned Android QA Fixture'
  if ($LASTEXITCODE -ne 0) { throw 'QA fixture key generation failed.' }
  $apk=Join-Path $qa 'fault-provider.apk'
  & (Join-Path $tools 'apksigner.bat') sign --ks $key --ks-key-alias qa --ks-pass pass:android --key-pass pass:android --out $apk (Join-Path $qa 'aligned.apk')
  if ($LASTEXITCODE -ne 0) { throw 'QA provider signing failed.' }
  & (Join-Path $tools 'apksigner.bat') verify $apk
  if ($LASTEXITCODE -ne 0) { throw 'QA provider signature verification failed.' }
  Assert-FileContract $sourceContract (Get-FileListContract -Root $sourceRoot -Files @(Get-TreeFiles -Root $sourceRoot)) 'QA provider sources after compilation'
  if ((Get-FileHash -LiteralPath $fixture -Algorithm SHA256).Hash.ToLowerInvariant() -ne $fixtureHash) { throw 'Shared valid ledger input changed during QA fixture compilation.' }
  $hash=(Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash.ToLowerInvariant()
  @{schemaVersion=1;qaOnly=$true;package='com.jianzhang.qa.faultprovider';source=$sourceContract;legacyLedgerFixtureSha256=$fixtureHash;apk=$apk;sha256=$hash;builtAt=[DateTimeOffset]::UtcNow.ToString('o')} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $qa 'manifest.json') -Encoding utf8
  Write-Host "QA-only provider APK: $apk"
  Write-Host "SHA-256: $hash"
} finally { [Environment]::SetEnvironmentVariable('JAVA_HOME',$previousJavaHome,'Process') }
