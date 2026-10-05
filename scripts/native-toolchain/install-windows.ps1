param([switch]$PrepareOnly)
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$downloads = Join-Path $workspace '.tools/downloads'
New-Item -ItemType Directory -Force -Path $downloads | Out-Null
$installer = Join-Path $downloads 'vs_buildtools.exe'
if (!(Test-Path -LiteralPath $installer)) {
  & curl.exe --silent --show-error --fail --location --retry 2 --connect-timeout 20 --max-time 300 --output $installer 'https://aka.ms/vs/17/release/vs_BuildTools.exe'
  if ($LASTEXITCODE -ne 0) { throw "Visual Studio bootstrapper download failed: curl exit $LASTEXITCODE" }
}
$signature = Get-AuthenticodeSignature -LiteralPath $installer
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Microsoft Corporation') {
  throw "Visual Studio bootstrapper Authenticode verification failed: $($signature.Status)"
}
Write-Host 'Verified Microsoft-signed Visual Studio Build Tools bootstrapper.'
if ($PrepareOnly) { return }
$administrator = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (!$administrator) {
  throw ('Windows C++ toolchain installation requires an administrator process. If AllSigned blocks this script, run the verified Microsoft-signed EXE directly in an administrator PowerShell: & "' + $installer + '" --passive --wait --norestart --installPath "' + (Join-Path $workspace '.tools/vs-buildtools') + '" --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.VC.ATL --includeRecommended. No execution-policy change or elevation prompt has been opened.')
}
$installRoot = Join-Path $workspace '.tools/vs-buildtools'
$arguments = '--quiet --wait --norestart --installPath "' + $installRoot + '" --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.VC.ATL --includeRecommended'
$process = Start-Process -FilePath $installer -ArgumentList $arguments -PassThru -WindowStyle Hidden
$process.WaitForExit()
if ($process.ExitCode -notin @(0,3010)) { throw "Visual Studio Build Tools installer failed: exit $($process.ExitCode)" }
Write-Host "Windows C++ toolchain installed, exit $($process.ExitCode)."
