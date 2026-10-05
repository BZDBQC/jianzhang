param([string]$Bundle,[string]$Output,[string]$QaRoot,[string]$BuildManifest)
$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$toolRoot=Join-Path $workspace '.tools'
$client=Join-Path $workspace 'clients/flutter'
. (Join-Path $PSScriptRoot 'native-toolchain/source-contract.ps1')
$envNames=@('TEMP','TMP','NSISDIR','PUB_CACHE','APPDATA','LOCALAPPDATA','DASH__SUPPRESS_ANALYTICS','FLUTTER_SUPPRESS_ANALYTICS')
$previous=@{}
foreach($name in $envNames) { $previous[$name]=[Environment]::GetEnvironmentVariable($name,'Process') }
function Assert-OwnedPath([string]$Path) {
  $resolved=[IO.Path]::GetFullPath($Path)
  if(!$resolved.StartsWith($workspace+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Packaging paths must remain inside the workspace.' }
  $ancestor=$resolved
  while($ancestor -and $ancestor -ne $workspace) {
    if(Test-Path -LiteralPath $ancestor) { if((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Packaging paths cannot traverse reparse points.' } }
    $ancestor=[IO.Path]::GetDirectoryName($ancestor)
  }
  return $resolved
}
function Get-ArtifactPublicationState([string]$Path) {
  $state=[pscustomobject]@{path=$Path;exists=[IO.File]::Exists($Path);length=$null;attributes=$null;sha256=$null;readError=$null}
  try {
    $file=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $state.exists=$true
    if($file.PSIsContainer) { throw 'Publication path is a directory.' }
    $state.length=$file.Length
    $state.attributes=$file.Attributes.ToString()
    $state.sha256=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
  } catch {
    $errorException=$_.Exception
    while($errorException.InnerException) { $errorException=$errorException.InnerException }
    $state.readError=[pscustomobject]@{type=$errorException.GetType().FullName;hresult=('0x'+$errorException.HResult.ToString('x8'));message=$errorException.Message}
  }
  return $state
}
function Publish-InstallerArtifact([string]$CandidatePath,[string]$OutputPath,[string]$DiagnosticRoot) {
  # Diagnostic files belong to this already validated, unique packaging input
  # directory. They never replace the old setup or its sidecar manifest.
  $before=[pscustomobject]@{candidate=(Get-ArtifactPublicationState $CandidatePath);output=(Get-ArtifactPublicationState $OutputPath);manifest=(Get-ArtifactPublicationState ($OutputPath+'.manifest.json'))}
  $encoding=[Text.UTF8Encoding]::new($false)
  [IO.File]::WriteAllText((Join-Path $DiagnosticRoot 'artifact-publication-before.json'),($before | ConvertTo-Json -Depth 7),$encoding)
  try {
    # PowerShell coerces ordinary $null to an empty string for this overload.
    # NullString passes a true null backup path and retains atomic replacement.
    if(Test-Path -LiteralPath $OutputPath) { [IO.File]::Replace($CandidatePath,$OutputPath,[NullString]::Value) } else { [IO.File]::Move($CandidatePath,$OutputPath) }
  } catch {
    $publicationError=$_
    $chain=[Collections.Generic.List[object]]::new()
    $errorException=$publicationError.Exception
    while($errorException) {
      $chain.Add([pscustomobject]@{type=$errorException.GetType().FullName;hresult=('0x'+$errorException.HResult.ToString('x8'));win32=$(if(($errorException.HResult -band 0x0fff0000) -eq 0x00070000){$errorException.HResult -band 0xffff}else{$null});message=$errorException.Message;stack=$errorException.StackTrace})
      $errorException=$errorException.InnerException
    }
    $failure=[pscustomobject]@{schemaVersion=1;status='failed';phase='atomic-artifact-publication';utc=[DateTime]::UtcNow.ToString('o');before=$before;after=[pscustomobject]@{candidate=(Get-ArtifactPublicationState $CandidatePath);output=(Get-ArtifactPublicationState $OutputPath);manifest=(Get-ArtifactPublicationState ($OutputPath+'.manifest.json'))};exceptions=$chain.ToArray();exceptionText=$publicationError.Exception.ToString();scriptStack=$publicationError.ScriptStackTrace;position=$publicationError.InvocationInfo.PositionMessage;retryAttempted=$false}
    try { [IO.File]::WriteAllText((Join-Path $DiagnosticRoot 'artifact-publication-failure.json'),($failure | ConvertTo-Json -Depth 9),$encoding) } catch { Write-Warning "Could not write publication diagnostics: $($_.Exception.Message)" }
    throw $publicationError
  }
}
try {
  $env:TEMP=Join-Path $toolRoot 'installer-temp'; $env:TMP=$env:TEMP
  $env:PUB_CACHE=Join-Path $toolRoot 'pub-cache'; $env:APPDATA=Join-Path $toolRoot 'flutter-config'; $env:LOCALAPPDATA=Join-Path $toolRoot 'flutter-config-local'
  $env:DASH__SUPPRESS_ANALYTICS='true'; $env:FLUTTER_SUPPRESS_ANALYTICS='true'
  New-Item -ItemType Directory -Force -Path $env:TEMP | Out-Null
  if(!$BuildManifest) { $BuildManifest=Join-Path $toolRoot 'windows-build-manifest.json' }
  $BuildManifest=Assert-OwnedPath $BuildManifest
  $build=Get-Content -LiteralPath $BuildManifest -Raw | ConvertFrom-Json
  if($build.schemaVersion -ne 2 -or !$build.source -or !$build.payload) { throw 'The native release requires a current schema-2 build manifest; rebuild before packaging.' }
  $buildManifestHash=(Get-FileHash -LiteralPath $BuildManifest -Algorithm SHA256).Hash.ToLowerInvariant()
  if(!$Bundle) { $Bundle=$build.bundle }
  $Bundle=Assert-OwnedPath $Bundle
  if($Bundle -ne [IO.Path]::GetFullPath($build.bundle)) { throw 'Bundle path differs from the recorded native build.' }
  $version=Get-ClientVersion -Root $client
  if($build.version -ne $version.version -or $build.versionCode -ne $version.versionCode) { throw 'Build version is stale or differs from pubspec.' }
  $release=Get-Content -LiteralPath (Join-Path $toolRoot 'downloads/flutter-release.json') -Raw | ConvertFrom-Json
  if($release.version -ne '3.47.6') { throw 'Packaging requires the selected official Flutter 3.47.6 release.' }
  $flutter=Assert-FlutterVersion -FlutterRoot (Join-Path $toolRoot 'flutter') -Release $release
  if($build.flutter.frameworkVersion -ne $flutter.frameworkVersion -or $build.flutter.frameworkRevision -ne $flutter.frameworkRevision -or $build.flutter.engineRevision -ne $flutter.engineRevision) { throw 'Flutter SDK differs from the release build record.' }
  Assert-FileContract $build.source (Get-ClientSourceContract -Root $client -Platform windows) 'Current source versus Windows build'
  Assert-WindowsPayload -Root $Bundle -PluginMetadata (Join-Path $client '.flutter-plugins-dependencies')
  Assert-FileContract $build.payload (Get-PayloadContract -Root $Bundle) 'Native release payload'
  if(!$Output) { $Output=Join-Path $workspace ('releases/windows/Jianzhang-'+$version.version+'-x64-setup.exe') }
  $Output=Assert-OwnedPath $Output
  New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($Output)) | Out-Null
  if($QaRoot) {
    $QaRoot=Assert-OwnedPath $QaRoot
    $qaBase=[IO.Path]::GetFullPath((Join-Path $workspace '.qa'))+[IO.Path]::DirectorySeparatorChar
    if(!$QaRoot.StartsWith($qaBase,[StringComparison]::OrdinalIgnoreCase)) { throw 'QA installer root must be an owned fixture under .qa.' }
    New-Item -ItemType Directory -Force -Path $QaRoot | Out-Null
  }
  $generated=Join-Path $toolRoot ('installer-input-'+[guid]::NewGuid().ToString('N'))
  $snapshot=Join-Path $generated 'payload'; $sources=Join-Path $generated 'sources'
  New-Item -ItemType Directory -Path $snapshot,$sources | Out-Null
  foreach($file in $build.payload.files) {
    $relative=$file.path.Replace('/','\')
    if($relative -match '[\r\n"$:]' -or [IO.Path]::IsPathRooted($relative) -or $relative.Split('\') -contains '..') { throw 'Unsafe installer payload path.' }
    $target=Join-Path $snapshot $relative
    New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($target)) | Out-Null
    Copy-Item -LiteralPath (Join-Path $Bundle $relative) -Destination $target
  }
  Assert-FileContract $build.payload (Get-PayloadContract -Root $snapshot) 'Copied native payload snapshot'
  $packaging=Join-Path $client 'packaging/windows'
  $sourcePaths=@((Join-Path $packaging 'installer.nsi'),(Join-Path $packaging 'icon.ico'),(Join-Path $workspace 'docs/native-user-guide.md'),(Join-Path $PSScriptRoot 'native-toolchain/installer-transaction.cs'))
  $packagingInputs=@()
  foreach($source in $sourcePaths) {
    $hash=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
    $name=[IO.Path]::GetFileName($source)
    Copy-Item -LiteralPath $source -Destination (Join-Path $sources $name)
    if((Get-FileHash -LiteralPath (Join-Path $sources $name) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $hash) { throw 'Packaging source changed during snapshot creation.' }
    $packagingInputs += [pscustomobject]@{source=$source;name=$name;sha256=$hash}
  }
  Copy-Item -LiteralPath (Join-Path $sources 'native-user-guide.md') -Destination (Join-Path $snapshot 'README.txt') -Force
  # CRT injection is confined to the packaging snapshot and recorded separately.
  $vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
  if(!(Test-Path -LiteralPath $vswhere)) { throw 'Visual Studio CRT redistributable discovery is unavailable.' }
  $vsRoot=(& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath).Trim()
  if(!$vsRoot) { throw 'No Visual Studio C++ installation found.' }
  $redist=Get-ChildItem -LiteralPath (Join-Path $vsRoot 'VC/Redist/MSVC') -Directory | Where-Object {$_.Name -match '^\d+\.\d+\.\d+$'} | Sort-Object {[version]$_.Name} -Descending | Select-Object -First 1
  if(!$redist) { throw 'Microsoft C++ redistributable version is missing.' }
  $crt=Get-ChildItem -LiteralPath (Join-Path $redist.FullName 'x64') -Directory | Where-Object {$_.Name -match '^Microsoft\.VC\d+\.CRT$'} | Select-Object -First 1
  if(!$crt) { throw 'Microsoft x64 CRT directory is missing.' }
  $crtFiles=@()
  foreach($name in @('msvcp140.dll','vcruntime140.dll','vcruntime140_1.dll')) {
    $source=Join-Path $crt.FullName $name
    if(!(Test-Path -LiteralPath $source -PathType Leaf)) { throw "Missing CRT library: $name" }
    $hash=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
    Copy-Item -LiteralPath $source -Destination (Join-Path $snapshot $name) -Force
    if((Get-FileHash -LiteralPath (Join-Path $snapshot $name) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $hash) { throw 'CRT library changed during copy.' }
    $crtFiles += [pscustomobject]@{path=$name;source=$source;sha256=$hash;fileVersion=[Diagnostics.FileVersionInfo]::GetVersionInfo($source).FileVersion}
  }
  $payload=Get-PayloadContract -Root $snapshot
  $config=Join-Path $generated 'transaction.json'
  @{version=$version.version;qaRoot=$QaRoot;files=$payload.files} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $config -Encoding utf8
  $configHash=(Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash.ToLowerInvariant()
  $helper=Join-Path $generated 'installer-transaction.exe'
  $csc=Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
  if(!(Test-Path -LiteralPath $csc)) { throw 'Windows built-in .NET Framework compiler is missing.' }
  $compileArgs=@('/nologo','/warnaserror+','/target:winexe','/platform:x86','/optimize+','/reference:System.Web.Extensions.dll',"/out:$helper")
  if($QaRoot) { $compileArgs += '/define:INSTALLER_QA' }
  $compileArgs += (Join-Path $sources 'installer-transaction.cs')
  & $csc @compileArgs
  if($LASTEXITCODE -ne 0) { throw "Installer transaction helper compilation failed: $LASTEXITCODE" }
  $helperHash=(Get-FileHash -LiteralPath $helper -Algorithm SHA256).Hash.ToLowerInvariant()
  $nsisRoot=Join-Path $toolRoot 'nsis-3.12'; $nsisDir=Join-Path $nsisRoot 'nsis-bundle/windows'; $compiler=Join-Path $nsisDir 'makensis.exe'
  if(!(Test-Path -LiteralPath $compiler)) {
    $download=Join-Path $toolRoot 'downloads/nsis-bundle-3.12.tar.gz'
    $expected='FE36A357F3A220DB893498E830FD80E0769768A18A99F4E4D2447B982538FEED'
    $prior=Join-Path $workspace 'native/windows/.cache/toolsets/nsis-bundle-3.12.tar.gz'
    if(Test-Path -LiteralPath $prior) { Copy-Item -LiteralPath $prior -Destination $download -Force }
    if(!(Test-Path -LiteralPath $download)) {
      & curl.exe --silent --show-error --fail --location --retry 2 --output $download 'https://github.com/electron-userland/electron-builder-binaries/releases/download/nsis%402.0.1/nsis-bundle-3.12.tar.gz'
      if($LASTEXITCODE -ne 0) { throw "NSIS download failed: $LASTEXITCODE" }
    }
    if((Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash -ne $expected) { throw 'NSIS compiler archive checksum mismatch.' }
    New-Item -ItemType Directory -Force -Path $nsisRoot | Out-Null
    & tar.exe -xf $download -C $nsisRoot
    if($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath $compiler)) { throw 'Verified NSIS extraction failed.' }
  }
  $env:NSISDIR=$nsisDir
  $checks=[Collections.Generic.List[string]]::new(); $deletions=[Collections.Generic.List[string]]::new(); $folders=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach($file in $payload.files) {
    $relative=$file.path.Replace('/','\')
    if($relative -match '[\r\n"$:]' -or $relative.Split('\') -contains '..') { throw 'Unsafe installer payload path.' }
    $checks.Add('!insertmacro CheckExistingFile "'+$relative+'"')
    # The helper verifies and deletes each owned file under a held replacement
    # lock; NSIS removes only empty owned directories after that succeeds.
    $parent=[IO.Path]::GetDirectoryName($relative)
    while($parent) { [void]$folders.Add($parent); $parent=[IO.Path]::GetDirectoryName($parent) }
  }
  foreach($folder in ($folders | Sort-Object Length -Descending)) { $deletions.Add('RMDir "$INSTDIR\'+$folder+'"'); $deletions.Add('ClearErrors') }
  $checksPath=Join-Path $generated 'bundle-checks.nsh'; $deletePath=Join-Path $generated 'bundle-delete.nsh'
  [IO.File]::WriteAllLines($checksPath,$checks,[Text.UTF8Encoding]::new($false)); [IO.File]::WriteAllLines($deletePath,$deletions,[Text.UTF8Encoding]::new($false))
  $candidate=Join-Path $generated 'candidate-setup.exe'
  $arguments=@('/V2',"/DAPP_VERSION=$($version.version)","/DBUNDLE_DIR=$snapshot","/DOUTPUT_FILE=$candidate","/DAPP_ICON=$(Join-Path $sources 'icon.ico')","/DBUNDLE_CHECKS=$checksPath","/DBUNDLE_DELETE=$deletePath","/DTX_HELPER=$helper","/DTX_CONFIG=$config","/DTX_CONFIG_SHA256=$configHash")
  if($QaRoot) { $arguments += @("/DQA_ROOT=$QaRoot","/DQA_OUTPUT=$candidate") }
  $arguments += (Join-Path $sources 'installer.nsi')
  & $compiler @arguments
  if($LASTEXITCODE -ne 0) { throw "Native installer compilation failed: $LASTEXITCODE" }
  # Recheck every input after NSIS reads it. Only a stable candidate is published.
  Assert-FileContract $build.source (Get-ClientSourceContract -Root $client -Platform windows) 'Sources after installer compilation'
  Assert-FileContract $build.payload (Get-PayloadContract -Root $Bundle) 'Release bundle after installer compilation'
  Assert-FileContract $payload (Get-PayloadContract -Root $snapshot) 'Packaging snapshot after installer compilation'
  if((Get-FileHash -LiteralPath $BuildManifest -Algorithm SHA256).Hash.ToLowerInvariant() -ne $buildManifestHash) { throw 'Build manifest changed during packaging.' }
  foreach($input in $packagingInputs) { if((Get-FileHash -LiteralPath $input.source -Algorithm SHA256).Hash.ToLowerInvariant() -ne $input.sha256 -or (Get-FileHash -LiteralPath (Join-Path $sources $input.name) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $input.sha256) { throw 'Installer source changed during compilation.' } }
  if((Get-FileHash -LiteralPath $helper -Algorithm SHA256).Hash.ToLowerInvariant() -ne $helperHash -or (Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash.ToLowerInvariant() -ne $configHash) { throw 'Transaction helper or manifest changed during compilation.' }
  # Publish by a same-volume rename/replace, preserving the previous setup if
  # the final output is occupied or the atomic replacement cannot be completed.
  $candidateHash=(Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToLowerInvariant()
  Publish-InstallerArtifact -CandidatePath $candidate -OutputPath $Output -DiagnosticRoot $generated
  $hash=(Get-FileHash -LiteralPath $Output -Algorithm SHA256).Hash.ToLowerInvariant()
  if($hash -ne $candidateHash) { throw 'Installer changed during atomic publication.' }
  $report=[pscustomobject]@{schemaVersion=2;version=$version.version;versionCode=$version.versionCode;status='candidate';installer=$Output;sha256=$hash;bundle=$Bundle;source=$build.source;buildManifestSha256=$buildManifestHash;buildPayload=$build.payload;payload=$payload;crtVersion=$redist.Name;crt=$crtFiles;packagingInputs=$packagingInputs;transactionHelperSha256=$helperHash;transactionConfigSha256=$configHash;qa=[bool]$QaRoot}
  $report | ConvertTo-Json -Depth 9 | Set-Content -LiteralPath ($Output+'.manifest.json') -Encoding utf8
  Write-Host "Candidate native installer: $Output"
  Write-Host "SHA256: $hash"
} finally {
  Restore-ProcessEnvironment $previous
}
