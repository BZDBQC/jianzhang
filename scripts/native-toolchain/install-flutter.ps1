param([string]$Version = '3.47.6')
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$toolRoot = Join-Path $workspace '.tools'
$downloadRoot = Join-Path $toolRoot 'downloads'
. (Join-Path $PSScriptRoot 'source-contract.ps1')
$envNames=@('PUB_CACHE','TEMP','TMP','DASH__SUPPRESS_ANALYTICS','FLUTTER_SUPPRESS_ANALYTICS','APPDATA','LOCALAPPDATA')
$previous=@{}
foreach($name in $envNames) { $previous[$name]=[Environment]::GetEnvironmentVariable($name,'Process') }
try {
$env:PUB_CACHE = Join-Path $toolRoot 'pub-cache'
$env:TEMP = Join-Path $toolRoot 'temp'
$env:TMP = $env:TEMP
$env:DASH__SUPPRESS_ANALYTICS = 'true'
$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
# Flutter's Windows Config explicitly uses APPDATA for its tool state.
# Keep this override scoped to this installation process, never user/global state.
$env:APPDATA = Join-Path $toolRoot 'flutter-config'
$env:LOCALAPPDATA = Join-Path $toolRoot 'flutter-config-local'
New-Item -ItemType Directory -Force -Path $env:PUB_CACHE, $env:TEMP, $env:APPDATA, $env:LOCALAPPDATA | Out-Null
New-Item -ItemType Directory -Force -Path $downloadRoot | Out-Null
$indexUrl = 'https://storage.googleapis.com/flutter_infra_release/releases/releases_windows.json'
$index = Invoke-RestMethod -Uri $indexUrl -TimeoutSec 30
$release = $index.releases | Where-Object { $_.version -eq $Version -and $_.channel -eq 'stable' } | Select-Object -First 1
if (!$release) { throw "Official stable release not found: $Version" }
$url = 'https://storage.googleapis.com/flutter_infra_release/releases/' + $release.archive
$archive = Join-Path $downloadRoot (Split-Path $release.archive -Leaf)
$release | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8 (Join-Path $downloadRoot 'flutter-release.json')
if (!(Test-Path -LiteralPath $archive) -or (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $release.sha256) {
  & curl.exe --silent --show-error --fail --location --continue-at - --retry 2 --retry-delay 3 --connect-timeout 20 --max-time 7200 --output $archive $url
  if ($LASTEXITCODE -ne 0) { throw "Flutter SDK download failed: curl exit $LASTEXITCODE ($url)" }
}
$actualHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualHash -ne $release.sha256) { throw "Flutter SDK SHA256 mismatch: expected $($release.sha256), got $actualHash" }
Write-Host "Verified Flutter $Version SHA256 $actualHash"
$flutterPath = Join-Path $toolRoot 'flutter'
try { $actual=Assert-FlutterVersion -FlutterRoot $flutterPath -Release $release; $sdkMatches=$true } catch { $sdkMatches=$false }
if (!$sdkMatches) {
  $staging=Join-Path $toolRoot ('flutter-install-'+[guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $staging | Out-Null
  & tar.exe -xf $archive -C $staging
  if ($LASTEXITCODE -ne 0) { throw "Flutter SDK extraction failed: tar exit $LASTEXITCODE" }
  $candidate=Join-Path $staging 'flutter'
  $actual=Assert-FlutterVersion -FlutterRoot $candidate -Release $release
  $backup=Join-Path $toolRoot ('flutter-previous-'+[guid]::NewGuid().ToString('N'))
  $owned=[IO.Path]::GetFullPath($toolRoot)+[IO.Path]::DirectorySeparatorChar
  foreach($path in @($flutterPath,$candidate,$backup)) { if(![IO.Path]::GetFullPath($path).StartsWith($owned,[StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe Flutter replacement path.' } }
  $movedOld=$false
  $movedCandidate=$false
  try {
    if(Test-Path -LiteralPath $flutterPath) {
      if((Get-Item -LiteralPath $flutterPath).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Flutter installation root must not be a link.' }
      Move-Item -LiteralPath $flutterPath -Destination $backup
      $movedOld=$true
    }
    Move-Item -LiteralPath $candidate -Destination $flutterPath
    $movedCandidate=$true
    $actual=Assert-FlutterVersion -FlutterRoot $flutterPath -Release $release
  } catch {
    if($movedOld) {
      if($movedCandidate -and (Test-Path -LiteralPath $flutterPath)) { Move-Item -LiteralPath $flutterPath -Destination (Join-Path $toolRoot ('flutter-failed-'+[guid]::NewGuid().ToString('N'))) }
      if(!(Test-Path -LiteralPath $flutterPath)) { Move-Item -LiteralPath $backup -Destination $flutterPath }
    }
    throw
  }
}
Write-Host "Verified installed Flutter $($actual.frameworkVersion), revision $($actual.frameworkRevision), channel $($actual.channel)."
} finally {
  Restore-ProcessEnvironment $previous
}
