param([string]$Version = '2.0.0', [int]$BuildNumber = 3)
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$client = Join-Path $workspace 'clients/flutter'
$buildClient = Join-Path $workspace '.tools/windows-build-client'
$flutter = Join-Path $workspace '.tools/flutter/bin/flutter.bat'
$pluginFile = Join-Path $client '.flutter-plugins-dependencies'
if (!(Test-Path -LiteralPath $pluginFile)) { throw 'Run client pub get once before building Windows.' }
$envNames = @('PUB_CACHE','TEMP','TMP','APPDATA','LOCALAPPDATA','DASH__SUPPRESS_ANALYTICS','FLUTTER_SUPPRESS_ANALYTICS')
$previous = @{}
foreach ($name in $envNames) { $previous[$name] = [Environment]::GetEnvironmentVariable($name,'Process') }
. (Join-Path $PSScriptRoot 'source-contract.ps1')
Assert-WorkspacePath -Workspace $workspace -Path $client | Out-Null
Assert-WorkspacePath -Workspace $workspace -Path $buildClient -AllowMissing | Out-Null
try {
  $env:PUB_CACHE = Join-Path $workspace '.tools/pub-cache'
  $env:TEMP = Join-Path $workspace '.tools/temp'
  $env:TMP = $env:TEMP
  $env:APPDATA = Join-Path $workspace '.tools/flutter-config'
  $env:LOCALAPPDATA = Join-Path $workspace '.tools/flutter-config-local'
  $env:DASH__SUPPRESS_ANALYTICS = 'true'
  $env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
  $release=Get-Content -LiteralPath (Join-Path $workspace '.tools/downloads/flutter-release.json') -Raw | ConvertFrom-Json
  if($release.version -ne '3.47.6') { throw 'The client build contract requires Flutter 3.47.6.' }
  $flutterVersion=Assert-FlutterVersion -FlutterRoot (Join-Path $workspace '.tools/flutter') -Release $release
  $clientVersion=Get-ClientVersion -Root $client
  if($clientVersion.version -ne $Version -or $clientVersion.versionCode -ne $BuildNumber) { throw 'Build version must match pubspec.' }
  $sourceContract = Get-ClientSourceContract -Root $client -Platform windows
  New-Item -ItemType Directory -Force -Path $buildClient | Out-Null
  # Unlink each known junction without recursion before refreshing the owning
  # platform directory. No operation traverses into PUB_CACHE.
  $oldLinks = Join-Path $buildClient 'windows/flutter/ephemeral/.plugin_symlinks'
  Assert-WorkspacePath -Workspace $workspace -Path $oldLinks -AllowMissing | Out-Null
  if (Test-Path -LiteralPath $oldLinks) {
    foreach ($link in Get-ChildItem -LiteralPath $oldLinks -Directory -Force) {
      if (!($link.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unexpected ordinary directory in the plugin junction directory.' }
      [IO.Directory]::Delete($link.FullName,$false)
    }
  }
  foreach ($directory in Get-ChildItem -LiteralPath $buildClient -Directory) {
    Assert-WorkspacePath -Workspace $workspace -Path $directory.FullName | Out-Null
    if ($directory.Name -in @('build','.dart_tool')) { continue }
    $ownedRoot = [IO.Path]::GetFullPath($buildClient) + [IO.Path]::DirectorySeparatorChar
    if (!$directory.FullName.StartsWith($ownedRoot,[StringComparison]::OrdinalIgnoreCase) -or ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unsafe Windows build snapshot path.' }
    Get-TreeFiles -Root $directory.FullName | Out-Null
    Remove-Item -LiteralPath $directory.FullName -Recurse -Force
  }
  foreach ($inputFile in Get-ClientSourceFiles -Root $client -Platform windows) {
    $relative = $inputFile.FullName.Substring($client.Length + 1)
    $target = Join-Path $buildClient $relative
    Assert-WorkspacePath -Workspace $workspace -Path $target -PathType File -AllowMissing | Out-Null
    New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($target)) | Out-Null
    Copy-Item -LiteralPath $inputFile.FullName -Destination $target -Force
  }
  Assert-FileContract $sourceContract (Get-ClientSourceContract -Root $buildClient -Platform windows) 'Windows source snapshot'
  Assert-FileContract $sourceContract (Get-ClientSourceContract -Root $client -Platform windows) 'Current Windows source'
  Assert-WorkspacePath -Workspace $workspace -Path (Join-Path $buildClient '.dart_tool') -AllowMissing | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $buildClient '.dart_tool') | Out-Null
  foreach ($metadata in @('package_config.json','package_graph.json')) {
    $target=Assert-WorkspacePath -Workspace $workspace -Path (Join-Path $buildClient ('.dart_tool/' + $metadata)) -PathType File -AllowMissing
    Copy-Item -LiteralPath (Join-Path $client ('.dart_tool/' + $metadata)) -Destination $target -Force
  }
  $target=Assert-WorkspacePath -Workspace $workspace -Path (Join-Path $buildClient '.flutter-plugins-dependencies') -PathType File -AllowMissing
  Copy-Item -LiteralPath $pluginFile -Destination $target -Force
  foreach ($generated in Get-ChildItem -LiteralPath (Join-Path $client 'windows/flutter') -File -Filter 'generated_*') {
    $target=Assert-WorkspacePath -Workspace $workspace -Path (Join-Path $buildClient ('windows/flutter/' + $generated.Name)) -PathType File -AllowMissing
    Copy-Item -LiteralPath $generated.FullName -Destination $target -Force
  }
  $bundle = Join-Path $buildClient 'build/windows/x64/runner/Release'
  Assert-WorkspacePath -Workspace $workspace -Path $bundle -AllowMissing | Out-Null
  if(Test-Path -LiteralPath $bundle) {
    Get-TreeFiles -Root $bundle | Out-Null
    $owned=[IO.Path]::GetFullPath($buildClient)+[IO.Path]::DirectorySeparatorChar
    if(![IO.Path]::GetFullPath($bundle).StartsWith($owned,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe Windows release cleanup path.' }
    Remove-Item -LiteralPath $bundle -Recurse -Force
  }
  $plugins = (Get-Content -LiteralPath $pluginFile -Raw | ConvertFrom-Json).plugins.windows
  $linkRoot = [IO.Path]::GetFullPath((Join-Path $buildClient 'windows/flutter/ephemeral/.plugin_symlinks'))
  Assert-WorkspacePath -Workspace $workspace -Path $linkRoot -AllowMissing | Out-Null
  New-Item -ItemType Directory -Force -Path $linkRoot | Out-Null
  foreach ($plugin in $plugins) {
    if ($plugin.name -notmatch '^[a-z][a-z0-9_]*$') { throw 'Invalid plugin name.' }
    $target = [IO.Path]::GetFullPath($plugin.path)
    $cacheRoot = [IO.Path]::GetFullPath($env:PUB_CACHE) + [IO.Path]::DirectorySeparatorChar
    if (!$target.StartsWith($cacheRoot,[StringComparison]::OrdinalIgnoreCase) -or !(Test-Path -LiteralPath $target -PathType Container)) { throw "Plugin target must exist in this project's PUB_CACHE: $($plugin.name)" }
    $link = Join-Path $linkRoot $plugin.name
    if (Test-Path -LiteralPath $link) {
      $existing = Get-Item -LiteralPath $link -Force
      if (!($existing.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Plugin link location contains an ordinary directory: $link" }
      $existingTarget = [IO.Path]::GetFullPath(@($existing.Target)[0])
      if ($existingTarget.TrimEnd('\') -ne $target.TrimEnd('\')) { throw "Stale plugin junction: $link. Remove only the link before rebuilding; do not recursively delete its target." }
    } else {
      # Dart Link.existsSync recognizes Windows junctions. They need no elevated
      # token, and Flutter can use the same plugin target paths through CMake.
      New-Item -ItemType Junction -Path $link -Target $target | Out-Null
    }
  }
  Push-Location $buildClient
  try {
    & $flutter --suppress-analytics build windows --release --no-pub "--build-name=$Version" "--build-number=$BuildNumber"
    if ($LASTEXITCODE -ne 0) { throw "Windows release build failed: exit $LASTEXITCODE" }
  } finally { Pop-Location }
  Assert-FileContract $sourceContract (Get-ClientSourceContract -Root $client -Platform windows) 'Windows sources after compilation'
  Assert-WindowsPayload -Root $bundle -PluginMetadata $pluginFile
  $payload=Get-PayloadContract -Root $bundle
  Assert-WorkspacePath -Workspace $workspace -Path (Join-Path $workspace '.tools/windows-build-manifest.json') -PathType File -AllowMissing | Out-Null
  @{schemaVersion=2;version=$Version;versionCode=$BuildNumber;sourceSha256=$sourceContract.sha256;source=$sourceContract;flutter=$flutterVersion;bundle=$bundle;payload=$payload;windows10RuntimeVerified=$false} | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8 (Join-Path $workspace '.tools/windows-build-manifest.json')
  Write-Host "Windows release bundle: $bundle"
} finally {
  Restore-ProcessEnvironment $previous
}
