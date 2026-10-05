param([int[]]$Api = @(26,29,33,35,36,37))
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $PSScriptRoot 'environment-scope.ps1')
$sdkRoot = Join-Path $workspace '.tools/android-sdk'
$avdRoot = Join-Path $workspace '.tools/avd'
$envNames=@('JAVA_HOME','ANDROID_HOME','ANDROID_SDK_ROOT','ANDROID_USER_HOME','ANDROID_AVD_HOME')
$previous=@{}
foreach($name in $envNames) { $previous[$name]=[Environment]::GetEnvironmentVariable($name,'Process') }
try {
$env:JAVA_HOME = 'C:\Program Files\Java\jdk-17.0.3.1'
$env:ANDROID_HOME = $sdkRoot
$env:ANDROID_SDK_ROOT = $sdkRoot
$env:ANDROID_USER_HOME = Join-Path $workspace '.tools/android-user-home'
$env:ANDROID_AVD_HOME = $avdRoot
New-Item -ItemType Directory -Force -Path $avdRoot | Out-Null
$sdkManager = Join-Path $sdkRoot 'cmdline-tools/19.0/bin/sdkmanager.bat'
$avdManager = Join-Path $sdkRoot 'cmdline-tools/19.0/bin/avdmanager.bat'
foreach ($version in $Api) {
  if ($version -notin @(26,29,33,35,36,37)) { throw "Unsupported test API: $version" }
  $package = if ($version -eq 37) { 'system-images;android-37.0;google_apis_ps16k;x86_64' } else { "system-images;android-$version;default;x86_64" }
  & $sdkManager "--sdk_root=$sdkRoot" $package
  if ($LASTEXITCODE -ne 0) { throw "Official API $version system image unavailable or installation failed: $package, exit $LASTEXITCODE" }
  $name = "Jianzhang_API$version"
  $path = Join-Path $avdRoot ($name + '.avd')
  if (!(Test-Path -LiteralPath $path)) {
    'no' | & $avdManager create avd --name $name --package $package --path $path --device pixel_2
    if ($LASTEXITCODE -ne 0) { throw "API $version AVD creation failed: exit $LASTEXITCODE" }
    $configFile = Join-Path $path 'config.ini'
    $config = Get-Content -LiteralPath $configFile | Where-Object { $_ -notmatch '^(hw.ramSize|disk.dataPartition.size|fastboot.forceColdBoot|fastboot.forceFastBoot|showDeviceFrame)=' }
    @($config) + @('hw.ramSize=2048','disk.dataPartition.size=2G','fastboot.forceColdBoot=yes','fastboot.forceFastBoot=no','showDeviceFrame=no') | Set-Content -Encoding ascii $configFile
  }
  Write-Host "Prepared API ${version}: $name ($package); device runtime not verified."
}
} finally {
  Restore-ProcessEnvironment $previous
}
