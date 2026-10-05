param([switch]$Emulator)
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $PSScriptRoot 'environment-scope.ps1')
$toolRoot = Join-Path $workspace '.tools'
$downloads = Join-Path $toolRoot 'downloads'
$sdkRoot = Join-Path $toolRoot 'android-sdk'
New-Item -ItemType Directory -Force -Path $downloads, $sdkRoot | Out-Null
$envNames=@('JAVA_HOME','ANDROID_SDK_ROOT','ANDROID_HOME','ANDROID_USER_HOME')
$previous=@{}
foreach($name in $envNames) { $previous[$name]=[Environment]::GetEnvironmentVariable($name,'Process') }
try {
$env:JAVA_HOME = 'C:\Program Files\Java\jdk-17.0.3.1'
$env:ANDROID_SDK_ROOT = $sdkRoot
$env:ANDROID_HOME = $sdkRoot
$env:ANDROID_USER_HOME = Join-Path $toolRoot 'android-user-home'
New-Item -ItemType Directory -Force -Path $env:ANDROID_USER_HOME | Out-Null
$repositoryUrl = 'https://dl.google.com/android/repository/repository2-3.xml'
$repositoryResponse = Invoke-WebRequest -UseBasicParsing -Uri $repositoryUrl -TimeoutSec 30
$repositoryText = if ($repositoryResponse.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($repositoryResponse.Content) } else { [string]$repositoryResponse.Content }
$repository = [xml]$repositoryText
$repositoryText | Set-Content -Encoding utf8 (Join-Path $downloads 'android-repository.xml')
function Install-Archive([string]$PackagePath, [string]$Destination, [string]$ArchiveFolder) {
  $package = $repository.SelectNodes("//*[local-name()='remotePackage']") | Where-Object { $_.path -eq $PackagePath -and (!$_.channelRef -or $_.channelRef.ref -eq 'channel-0') } | Select-Object -First 1
  if (!$package) { throw "Android stable package not found: $PackagePath" }
  $selected = $package.archives.archive | Where-Object { $_.('host-os') -eq 'windows' } | Select-Object -First 1
  if (!$selected) { throw "Android Windows archive not found: $PackagePath" }
  $archive = Join-Path $downloads $selected.complete.url
  $expected = [string]$selected.complete.checksum.InnerText
  if (!(Test-Path -LiteralPath $archive) -or (Get-FileHash -LiteralPath $archive -Algorithm SHA1).Hash.ToLowerInvariant() -ne $expected) {
    & curl.exe --silent --show-error --fail --location --retry 2 --connect-timeout 20 --max-time 3600 --output $archive ('https://dl.google.com/android/repository/' + $selected.complete.url)
    if ($LASTEXITCODE -ne 0) { throw "Android download failed: $PackagePath, curl exit $LASTEXITCODE" }
  }
  if ((Get-FileHash -LiteralPath $archive -Algorithm SHA1).Hash.ToLowerInvariant() -ne $expected) { throw "Android official checksum mismatch: $PackagePath" }
  if (!(Test-Path -LiteralPath $Destination)) {
    $staging = Join-Path $toolRoot ('extract-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $staging, (Split-Path $Destination -Parent) | Out-Null
    & tar.exe -xf $archive -C $staging
    if ($LASTEXITCODE -ne 0) { throw "Android extraction failed: $PackagePath" }
    Move-Item -LiteralPath (Join-Path $staging $ArchiveFolder) -Destination $Destination
  }
  # ZIP extraction alone omits SDK-manager metadata. AVD-manager requires a
  # registered emulator package. Preserve the official revision and license.
  $packageXml = Join-Path $Destination 'package.xml'
  if (!(Test-Path -LiteralPath $packageXml)) {
    $localDocument = New-Object Xml.XmlDocument
    $localRoot = $localDocument.CreateElement('common','repository','http://schemas.android.com/repository/android/common/02')
    foreach ($attribute in $repository.DocumentElement.Attributes) { $localRoot.SetAttribute($attribute.Name,$attribute.Value) }
    $localDocument.AppendChild($localRoot) | Out-Null
    $licenseRef = $package.'uses-license'.ref
    foreach ($license in $repository.SelectNodes("//*[local-name()='license']")) {
      if ($license.id -eq $licenseRef) { $localRoot.AppendChild($localDocument.ImportNode($license,$true)) | Out-Null }
    }
    $localPackage = $localDocument.CreateElement('localPackage')
    $localPackage.SetAttribute('path',$PackagePath)
    $localPackage.SetAttribute('obsolete','false')
    foreach ($elementName in @('type-details','revision','display-name','uses-license')) {
      $element = $package.SelectSingleNode("*[local-name()='$elementName']")
      if ($element) { $localPackage.AppendChild($localDocument.ImportNode($element,$true)) | Out-Null }
    }
    $localRoot.AppendChild($localPackage) | Out-Null
    $localDocument.Save($packageXml)
  }
  Write-Host "Verified Android package $PackagePath"
}
Install-Archive 'cmdline-tools;latest' (Join-Path $sdkRoot 'cmdline-tools/latest') 'cmdline-tools'
Install-Archive 'cmdline-tools;19.0' (Join-Path $sdkRoot 'cmdline-tools/19.0') 'cmdline-tools'
Install-Archive 'platform-tools' (Join-Path $sdkRoot 'platform-tools') 'platform-tools'
if ($Emulator) { Install-Archive 'emulator' (Join-Path $sdkRoot 'emulator') 'emulator' }
$sdkManager = Join-Path $sdkRoot 'cmdline-tools/19.0/bin/sdkmanager.bat'
(1..100 | ForEach-Object { 'y' }) | & $sdkManager "--sdk_root=$sdkRoot" --licenses
if ($LASTEXITCODE -ne 0) { throw "Android license setup failed: exit $LASTEXITCODE" }
& $sdkManager "--sdk_root=$sdkRoot" 'platforms;android-36' 'build-tools;36.0.0' 'ndk;28.2.13676358' 'cmake;3.22.1'
if ($LASTEXITCODE -ne 0) { throw "Android SDK packages failed: exit $LASTEXITCODE" }
Write-Host "Android SDK ready: $sdkRoot"
} finally {
  Restore-ProcessEnvironment $previous
}
