param([string]$Version = '2.0.0', [int]$BuildNumber = 3)
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$client = Join-Path $workspace 'clients/flutter'
$buildClient = Join-Path $workspace '.tools/android-build-client'
$sdk = Join-Path $workspace '.tools/android-sdk'
$flutter = Join-Path $workspace '.tools/flutter/bin/flutter.bat'
$signing = Join-Path $workspace 'native/android/.signing'
$keyStore = Join-Path $signing 'release.keystore'
$passwordFile = Join-Path $signing 'password.txt'
if (!(Test-Path -LiteralPath $keyStore) -or !(Test-Path -LiteralPath $passwordFile)) { throw 'Existing Android release signing material is unavailable.' }
. (Join-Path $PSScriptRoot 'source-contract.ps1')
Assert-WorkspacePath -Workspace $workspace -Path $client | Out-Null
Assert-WorkspacePath -Workspace $workspace -Path $buildClient -AllowMissing | Out-Null
$envNames = @('JAVA_HOME','ANDROID_HOME','ANDROID_SDK_ROOT','ANDROID_USER_HOME','PUB_CACHE','GRADLE_USER_HOME','TEMP','TMP','APPDATA','LOCALAPPDATA','DASH__SUPPRESS_ANALYTICS','FLUTTER_SUPPRESS_ANALYTICS','JIANZHANG_KEYSTORE_PATH','JIANZHANG_KEYSTORE_PASSWORD')
$previous = @{}
foreach ($name in $envNames) { $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
try {
  $env:JAVA_HOME = 'C:\Program Files\Java\jdk-17.0.3.1'
  $env:ANDROID_HOME = $sdk
  $env:ANDROID_SDK_ROOT = $sdk
  $env:ANDROID_USER_HOME = Join-Path $workspace '.tools/android-user-home'
  $env:PUB_CACHE = Join-Path $workspace '.tools/pub-cache'
  $env:GRADLE_USER_HOME = Join-Path $workspace '.tools/gradle-cache'
  $env:TEMP = Join-Path $workspace '.tools/temp'
  $env:TMP = $env:TEMP
  $env:DASH__SUPPRESS_ANALYTICS = 'true'
  $env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
  $env:APPDATA = Join-Path $workspace '.tools/flutter-config'
  $env:LOCALAPPDATA = Join-Path $workspace '.tools/flutter-config-local'
  $env:JIANZHANG_KEYSTORE_PATH = $keyStore
  $env:JIANZHANG_KEYSTORE_PASSWORD = (Get-Content -LiteralPath $passwordFile -Raw).Trim()
  # A single-platform build snapshot does not generate Windows plugin symlinks.
  # It leaves source files intact and avoids requiring Developer Mode for APK builds.
  New-Item -ItemType Directory -Force -Path $buildClient | Out-Null
  # Refresh all source and asset directories, including custom paths declared in
  # pubspec. Build outputs and other platform projects are never copied.
  $release=Get-Content -LiteralPath (Join-Path $workspace '.tools/downloads/flutter-release.json') -Raw | ConvertFrom-Json
  if($release.version -ne '3.47.6') { throw 'The client build contract requires Flutter 3.47.6.' }
  $flutterVersion=Assert-FlutterVersion -FlutterRoot (Join-Path $workspace '.tools/flutter') -Release $release
  $clientVersion=Get-ClientVersion -Root $client
  if($clientVersion.version -ne $Version -or $clientVersion.versionCode -ne $BuildNumber) { throw 'Build version must match pubspec.' }
  $sourceBefore = Get-ClientSourceContract -Root $client -Platform android
  $metadataBefore = Get-AndroidMetadataContract -Root $client
  foreach ($directory in Get-ChildItem -LiteralPath $buildClient -Directory) {
    Assert-WorkspacePath -Workspace $workspace -Path $directory.FullName | Out-Null
    if ($directory.Name -in @('build','.dart_tool')) { continue }
    $target = [IO.Path]::GetFullPath($directory.FullName)
    $ownedRoot = [IO.Path]::GetFullPath($buildClient) + [IO.Path]::DirectorySeparatorChar
    if (!$target.StartsWith($ownedRoot, [StringComparison]::OrdinalIgnoreCase) -or ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Build snapshot target is outside its owned directory or is a link.' }
    Get-TreeFiles -Root $target | Out-Null
    Remove-Item -LiteralPath $target -Recurse -Force
  }
  foreach ($inputFile in Get-ClientSourceFiles -Root $client -Platform android) {
    $relative = $inputFile.FullName.Substring($client.Length + 1)
    $target = Join-Path $buildClient $relative
    Assert-WorkspacePath -Workspace $workspace -Path $target -PathType File -AllowMissing | Out-Null
    New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($target)) | Out-Null
    Copy-Item -LiteralPath $inputFile.FullName -Destination $target -Force
  }
  Assert-FileContract $sourceBefore (Get-ClientSourceContract -Root $buildClient -Platform android) 'Android source snapshot'
  Assert-FileContract $sourceBefore (Get-ClientSourceContract -Root $client -Platform android) 'Current Android source'
  Assert-WorkspacePath -Workspace $workspace -Path (Join-Path $buildClient '.dart_tool') -AllowMissing | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $buildClient '.dart_tool') | Out-Null
  foreach ($metadata in @('package_config.json','package_graph.json')) {
    $target=Assert-WorkspacePath -Workspace $workspace -Path (Join-Path $buildClient ('.dart_tool/' + $metadata)) -PathType File -AllowMissing
    Copy-Item -LiteralPath (Join-Path $client ('.dart_tool/' + $metadata)) -Destination $target -Force
  }
  if (Test-Path -LiteralPath (Join-Path $client '.flutter-plugins-dependencies')) {
    $target=Assert-WorkspacePath -Workspace $workspace -Path (Join-Path $buildClient '.flutter-plugins-dependencies') -PathType File -AllowMissing
    Copy-Item -LiteralPath (Join-Path $client '.flutter-plugins-dependencies') -Destination $target -Force
  }
  Assert-FileContract $metadataBefore (Get-AndroidMetadataContract -Root $buildClient) 'Android copied package metadata'
  Push-Location $buildClient
  try {
    # --no-pub also skips Flutter's release-mode plugin regeneration. Use the
    # official generation phase so a preceding native test cannot leave a dev
    # registrant in the release build; the locked source contract stays checked.
    & $flutter --suppress-analytics build apk --release --target-platform android-arm,android-arm64,android-x64 "--build-name=$Version" "--build-number=$BuildNumber"
    if ($LASTEXITCODE -ne 0) { throw "Android release build failed: exit $LASTEXITCODE" }
  } finally { Pop-Location }
  Assert-FileContract $sourceBefore (Get-ClientSourceContract -Root $buildClient -Platform android) 'Android compiled handwritten inputs'
  $generatedInputs=Get-AndroidMetadataContract -Root $buildClient -IncludeRegistrant
  $apk = Join-Path $buildClient 'build/app/outputs/flutter-apk/app-release.apk'
  $buildTools = Join-Path $sdk 'build-tools/36.0.0'
  $verify = & (Join-Path $buildTools 'apksigner.bat') verify --verbose --print-certs $apk 2>&1
  if ($LASTEXITCODE -ne 0) { throw 'APK signature verification failed.' }
  $certificate = ($verify | Select-String 'Signer #1 certificate SHA-256 digest:').Line.Split(':')[-1].Trim()
  $expectedCertificate = 'c398060dfa1cca49974bec7cf030ae818a4e1d83a91796c3c8152ce4c6e48c10'
  if ($certificate -ne $expectedCertificate) { throw 'APK signing identity differs from the existing installed app.' }
  & (Join-Path $buildTools 'zipalign.exe') -c -P 16 4 $apk
  if ($LASTEXITCODE -ne 0) { throw 'APK 16 KB ZIP alignment verification failed.' }
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $archive = [IO.Compression.ZipFile]::OpenRead($apk)
  $nativeChecks = @()
  try {
    foreach ($entry in $archive.Entries) {
      if ($entry.FullName -notmatch '^lib/(arm64-v8a|x86_64)/.+\.so$') { continue }
      $input = $entry.Open()
      $bytes = New-Object IO.MemoryStream
      try { $input.CopyTo($bytes); $elf = $bytes.ToArray() } finally { $input.Dispose(); $bytes.Dispose() }
      if ($elf.Length -lt 64 -or $elf[0] -ne 0x7f -or $elf[1] -ne 69 -or $elf[2] -ne 76 -or $elf[3] -ne 70 -or $elf[4] -ne 2 -or $elf[5] -ne 1) { throw "Unexpected ELF format: $($entry.FullName)" }
      $phOffset = [BitConverter]::ToUInt64($elf,32)
      $phEntry = [BitConverter]::ToUInt16($elf,54)
      $phCount = [BitConverter]::ToUInt16($elf,56)
      if ($phEntry -lt 56 -or $phOffset + $phEntry * $phCount -gt $elf.Length) { throw "Invalid ELF segment table: $($entry.FullName)" }
      $loads = 0
      for ($i = 0; $i -lt $phCount; $i++) {
        $offset = [int]($phOffset + $i * $phEntry)
        if ([BitConverter]::ToUInt32($elf,$offset) -ne 1) { continue }
        $loads++
        $fileOffset = [BitConverter]::ToUInt64($elf,$offset+8)
        $virtualAddress = [BitConverter]::ToUInt64($elf,$offset+16)
        $alignment = [BitConverter]::ToUInt64($elf,$offset+48)
        if ($alignment -lt 16384 -or $fileOffset % 16384 -ne $virtualAddress % 16384) { throw "ELF segment is not 16 KB compatible: $($entry.FullName)" }
      }
      if ($loads -eq 0) { throw "ELF has no loadable segments: $($entry.FullName)" }
      $nativeChecks += $entry.FullName
    }
  } finally { $archive.Dispose() }
  if (!$nativeChecks.Count) { throw 'Release APK has no checked 64-bit native libraries.' }
  $badging = & (Join-Path $buildTools 'aapt.exe') dump badging $apk
  if ($LASTEXITCODE -ne 0 -or !($badging -match "name='com.jianzhang.ledger'") -or !($badging -match "versionCode='$BuildNumber'") -or !($badging -match "versionName='$Version'") -or !($badging -match "sdkVersion:'26'")) { throw 'APK package, version or minimum SDK verification failed.' }
  $releaseDir = Join-Path $workspace 'releases/android'
  Assert-WorkspacePath -Workspace $workspace -Path $releaseDir -AllowMissing | Out-Null
  New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null
  $output = Join-Path $releaseDir "jianzhang-$Version.apk"
  foreach($published in @($output,(Join-Path $releaseDir "SHA256SUMS-$Version"),(Join-Path $releaseDir "source-manifest-$Version.json"),(Join-Path $releaseDir "release-manifest-$Version.json"))) {
    Assert-WorkspacePath -Workspace $workspace -Path $published -PathType File -AllowMissing | Out-Null
  }
  Assert-FileContract $sourceBefore (Get-ClientSourceContract -Root $client -Platform android) 'Android sources after compilation'
  Copy-Item -LiteralPath $apk -Destination $output -Force
  $sha256 = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant()
  "$sha256  jianzhang-$Version.apk" | Set-Content -Encoding ascii (Join-Path $releaseDir "SHA256SUMS-$Version")
  $sourceBefore | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8 (Join-Path $releaseDir "source-manifest-$Version.json")
  @{ schemaVersion=2;version=$Version;versionCode=$BuildNumber;flutter=$flutterVersion;package='com.jianzhang.ledger';minSdk=26;sha256=$sha256;sourceSha256=$sourceBefore.sha256;copiedPackageMetadata=$metadataBefore;generatedInputs=$generatedInputs;certificateSha256=$certificate;zipAlignment16KB=$true;nativeLibraries16KB=$nativeChecks;deviceInstallationVerified=$false } | ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8 (Join-Path $releaseDir "release-manifest-$Version.json")
  Write-Host "Verified release APK: $output"
} finally {
  Restore-ProcessEnvironment $previous
}
