param([int]$Api = 26)
$ErrorActionPreference = 'Stop'
if ($Api -notin @(26,29,33,35,36,37)) { throw "Unsupported test API: $Api" }
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $PSScriptRoot 'environment-scope.ps1')
$envNames=@('ANDROID_AVD_HOME','ANDROID_USER_HOME','ANDROID_EMULATOR_HOME','TEMP','TMP','APPDATA','LOCALAPPDATA')
$previous=@{}
foreach($name in $envNames) { $previous[$name]=[Environment]::GetEnvironmentVariable($name,'Process') }
try {
$env:ANDROID_AVD_HOME = Join-Path $workspace '.tools/avd'
$env:ANDROID_USER_HOME = Join-Path $workspace '.tools/android-user-home'
$env:ANDROID_EMULATOR_HOME = $env:ANDROID_USER_HOME
$env:TEMP = Join-Path $workspace '.tools/temp'
$env:TMP = $env:TEMP
$env:APPDATA = Join-Path $workspace '.tools/flutter-config'
$env:LOCALAPPDATA = Join-Path $workspace '.tools/flutter-config-local'
$sdkRoot = Join-Path $workspace '.tools/android-sdk'
$adb = Join-Path $sdkRoot 'platform-tools/adb.exe'
$emulator = Join-Path $sdkRoot 'emulator/emulator.exe'
$connected = & $adb devices
if ($LASTEXITCODE -ne 0) { throw 'ADB server startup failed; inspect the project-local temp adb.log.' }
if ($connected -match '^emulator-\d+\s') { throw 'An emulator is already running; stop it before starting another test device.' }
$name = "Jianzhang_API$Api"
if (!(Test-Path -LiteralPath (Join-Path $env:ANDROID_AVD_HOME ($name+'.avd/config.ini')))) { throw "AVD has not been prepared: $name" }
$logRoot = Join-Path $workspace '.qa/emulators'
New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
$outLog = Join-Path $logRoot "$name.out.log"
$errLog = Join-Path $logRoot "$name.err.log"
$memoryMB = if ($Api -eq 37) { 4096 } else { 2048 }
$process = Start-Process -FilePath $emulator -ArgumentList @('-avd',$name,'-no-window','-no-snapshot','-no-audio','-gpu','software','-memory',"$memoryMB",'-port','5554') -WindowStyle Hidden -PassThru -RedirectStandardOutput $outLog -RedirectStandardError $errLog
Write-Host "Started owned emulator process $($process.Id), API $Api, RAM $memoryMB MB, serial emulator-5554."
$process.Id | Set-Content -Encoding ascii (Join-Path $logRoot 'current-process-id.txt')
} finally {
  Restore-ProcessEnvironment $previous
}
