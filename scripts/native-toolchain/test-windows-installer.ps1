param(
  [Parameter(Mandatory=$true)][string]$Setup,
  [Parameter(Mandatory=$true)][string]$QaRoot,
  [Parameter(Mandatory=$true)][string]$OutputDirectory,
  [Parameter(Mandatory=$true)][string]$BuildId,
  [Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z0-9_-]+$')][string]$RoundId
)
$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $PSScriptRoot 'source-contract.ps1')
$setupPath=Assert-WorkspacePath -Workspace $workspace -Path $Setup -PathType File
$qaPath=Assert-WorkspacePath -Workspace $workspace -Path $QaRoot -PathType Directory
$outputPath=Assert-WorkspacePath -Workspace $workspace -Path $OutputDirectory -PathType Directory -AllowMissing
foreach($path in @($setupPath,$qaPath,$outputPath)) {
  if(!$path.StartsWith((Join-Path $workspace '.qa')+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Only task-owned QA installers and directories may be exercised.' }
}
if($qaPath -match '[\r\n"]') { throw 'Unsupported QA command path.' }
$deliveryPath=Assert-WorkspacePath -Workspace $workspace -Path ($setupPath+'.manifest.json') -PathType File
$deliveryHash=(Get-FileHash -LiteralPath $deliveryPath -Algorithm SHA256).Hash.ToLowerInvariant()
$delivery=Get-Content -LiteralPath $deliveryPath -Raw | ConvertFrom-Json
if($delivery.schemaVersion -ne 2 -or $delivery.qa -ne $true -or
   (Get-FileHash -LiteralPath $setupPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $delivery.sha256) {
  throw 'A verified instrumented QA installer with the complete release payload is required.'
}
function Assert-CurrentSources {
  Assert-FileContract $delivery.source (Get-ClientSourceContract -Root (Join-Path $workspace 'clients/flutter') -Platform windows) 'QA installer current client sources'
  foreach($packagingInput in $delivery.packagingInputs) {
    $inputPath=Assert-WorkspacePath -Workspace $workspace -Path $packagingInput.source -PathType File
    if((Get-FileHash -LiteralPath $inputPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $packagingInput.sha256) { throw 'QA installer packaging/helper source is stale.' }
  }
  if((Get-FileHash -LiteralPath $setupPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $delivery.sha256 -or
     (Get-FileHash -LiteralPath $deliveryPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $deliveryHash) { throw 'QA setup or recorded provenance changed during the run.' }
}
Assert-CurrentSources
New-Item -ItemType Directory -Force -Path $outputPath | Out-Null
$startedAt=[DateTimeOffset]::UtcNow.ToString('o')
$cases=[Collections.Generic.List[object]]::new()
$registrationPath='Software\Jianzhang\NativeInstallerQA'
function Assert-True([bool]$Condition,[string]$Message) { if(!$Condition) { throw $Message } }
function Qa-Child([string]$Parent,[string]$Name,[string]$PathType='Directory') {
  $child=Assert-WorkspacePath -Workspace $workspace -Path (Join-Path $Parent $Name) -PathType $PathType -AllowMissing
  if(!$child.StartsWith($qaPath+'\',[StringComparison]::OrdinalIgnoreCase) -and !$child.StartsWith($outputPath+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Derived QA path escaped the owned fixture.' }
  return $child
}
function Snapshot([string]$Directory) {
  if(!(Test-Path -LiteralPath $Directory -PathType Container)) { return @{} }
  $map=@{}
  foreach($file in Get-TreeFiles -Root $Directory) {
    $map[$file.FullName.Substring($Directory.Length+1)]=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
  }
  return $map
}
function Assert-Snapshot([string]$Directory,$Expected) {
  $actual=Snapshot $Directory
  Assert-True ($actual.Count -eq $Expected.Count) 'Rollback changed the number of installed files.'
  foreach($key in $Expected.Keys) { Assert-True ($actual[$key] -eq $Expected[$key]) ('Rollback changed '+$key) }
}
function Assert-Registration([string]$Location) {
  # This assertion belongs to the complete installer workflow; no standalone
  # registry creation, permission probe or production registration is performed.
  $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($registrationPath,$false)
  try {
    if(!$Location) { Assert-True ($null -eq $key) 'Failed first install left a registration.' }
    else {
      Assert-True ($null -ne $key) 'Installer registration is missing.'
      Assert-True ($key.GetValue('InstallLocation') -eq $Location) 'Registration points to another directory.'
      Assert-True ($key.GetValue('DisplayVersion') -eq '2.0.0') 'Registration version differs.'
    }
  } finally { if($key) { $key.Dispose() } }
}
function Registration-Snapshot {
  $records=[Collections.Generic.List[object]]::new()
  function Visit-Key($Key,[string]$Relative) {
    $records.Add(@{key=$Relative;kind='key'})
    foreach($name in @($Key.GetValueNames() | Sort-Object)) {
      $value=$Key.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
      $records.Add(@{key=$Relative;name=$name;kind=[int]$Key.GetValueKind($name);value=$value})
    }
    foreach($name in @($Key.GetSubKeyNames() | Sort-Object)) {
      $child=$Key.OpenSubKey($name,$false)
      try { Visit-Key $child ($Relative+'/'+$name) } finally { $child.Dispose() }
    }
  }
  $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($registrationPath,$false)
  try {
    if($key) { Visit-Key $key '' }
    return (@{exists=($null -ne $key);records=$records.ToArray()} | ConvertTo-Json -Depth 20 -Compress)
  } finally { if($key) { $key.Dispose() } }
}
function Assert-Payload([string]$Directory) {
  foreach($file in $delivery.payload.files) {
    $path=Assert-WorkspacePath -Workspace $workspace -Path (Join-Path $Directory $file.path.Replace('/','\')) -PathType File
    Assert-True ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -eq $file.sha256) ('Installed payload mismatch: '+$file.path)
  }
  foreach($entry in @('Uninstall.exe','.jianzhang-install-id','.jianzhang-payload.json','_qa/menu/简账.lnk','_qa/menu/卸载简账.lnk','_qa/desktop/简账.lnk')) {
    Assert-WorkspacePath -Workspace $workspace -Path (Join-Path $Directory $entry) -PathType File | Out-Null
  }
  Assert-Registration $Directory
}
function Run-Process([string]$File,[string]$Arguments,[int[]]$Expected) {
  $info=[Diagnostics.ProcessStartInfo]::new()
  $info.FileName=$File; $info.Arguments=$Arguments
  $info.UseShellExecute=$false; $info.CreateNoWindow=$true
  $info.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
  $process=[Diagnostics.Process]::new(); $process.StartInfo=$info
  $launched=$false
  try {
    if(!$process.Start()) { throw 'Could not start the actual installer.' }
    $launched=$true
    if(!$process.WaitForExit(120000)) { throw 'Owned installer exceeded its deadline.' }
    $exitCode=$process.ExitCode
    Assert-True ($exitCode -in $Expected) ("Unexpected installer exit $exitCode for $Arguments")
    return $exitCode
  } finally {
    if($launched -and !$process.HasExited) { $process.Kill(); $process.WaitForExit() }
    $process.Dispose()
  }
}
function Install([string]$Directory,[int]$Failure=0,[int]$Crash=0) {
  $arguments='/S'
  $expected=@(0)
  if($Failure) { $arguments+=" /QAFAIL=$Failure"; $expected=@(2) }
  if($Crash) { $arguments+=" /QACRASH=$Crash"; $expected=@(99) }
  $arguments+=' /D='+$Directory
  Run-Process $setupPath $arguments $expected | Out-Null
}
function Uninstall([string]$Directory,[bool]$MustSucceed=$true) {
  $uninstaller=Assert-WorkspacePath -Workspace $workspace -Path (Join-Path $Directory 'Uninstall.exe') -PathType File
  # Run a byte-identical owned copy with _?=, allowing the installed executable
  # to be removed and making exit status reflect the actual work, not a launcher.
  $copyDirectory=Qa-Child $outputPath ('uninstall-run-'+[guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $copyDirectory | Out-Null
  $copy=Qa-Child $copyDirectory 'Uninstall.exe' 'File'
  try {
    Copy-Item -LiteralPath $uninstaller -Destination $copy
    Assert-WorkspacePath -Workspace $workspace -Path $copy -PathType File | Out-Null
    Assert-True ((Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $uninstaller -Algorithm SHA256).Hash) 'Uninstaller QA copy differs.'
    Run-Process $copy ('/S _?='+$Directory) $(if($MustSucceed){@(0)}else{@(2)}) | Out-Null
  } finally {
    Assert-WorkspacePath -Workspace $workspace -Path $copyDirectory -PathType Directory | Out-Null
    if(Test-Path -LiteralPath $copy -PathType Leaf) {
      Assert-WorkspacePath -Workspace $workspace -Path $copy -PathType File | Out-Null
      Remove-Item -LiteralPath $copy
    }
    [IO.Directory]::Delete($copyDirectory,$false)
  }
}
function Case([string]$Name,[scriptblock]$Action) {
  $begin=[DateTimeOffset]::UtcNow.ToString('o')
  & $Action
  $cases.Add(@{name=$Name;status='pass';startedAt=$begin;finishedAt=[DateTimeOffset]::UtcNow.ToString('o')})
  Write-Host "PASS $Name"
}
$target=Qa-Child $qaPath ('安装 空格-'+$RoundId)
$external=Qa-Child $qaPath ('账本 数据-'+$RoundId)
New-Item -ItemType Directory -Path $external | Out-Null
$ledgerMarker=Qa-Child $external 'ledger-retention.txt' 'File'
[IO.File]::WriteAllText($ledgerMarker,'owned fixture outside the program directory',[Text.UTF8Encoding]::new($false))
$ledgerHash=(Get-FileHash -LiteralPath $ledgerMarker -Algorithm SHA256).Hash
try {
  Case 'first-install-full-payload-Chinese-space-path' { Install $target; Assert-Payload $target }
  $personal=Qa-Child $target 'data/个人导出.json' 'File'
  [IO.File]::WriteAllText($personal,'{"note":"保留用户文件"}',[Text.UTF8Encoding]::new($false))
  $personalHash=(Get-FileHash -LiteralPath $personal -Algorithm SHA256).Hash
  Case 'upgrade-preserves-personal-files' {
    Install $target; Assert-Payload $target
    Assert-True ((Get-FileHash -LiteralPath $personal -Algorithm SHA256).Hash -eq $personalHash) 'Upgrade removed a personal file.'
  }
  # Clean the committed recovery copy before taking exact snapshots.
  Install $target
  $baseline=Snapshot $target
  $registrationBaseline=Registration-Snapshot
  for($failure=1;$failure -le 18;$failure++) {
    Case ('upgrade-injected-failure-'+$failure) {
      Install $target -Failure $failure
      Assert-Snapshot $target $baseline; Assert-Registration $target
      Assert-True ((Registration-Snapshot) -eq $registrationBaseline) 'Failure changed registered values, types or child keys.'
      Install $target; Assert-Payload $target
      Assert-True ((Get-FileHash -LiteralPath $personal -Algorithm SHA256).Hash -eq $personalHash) 'Retry changed a personal file.'
      $script:baseline=Snapshot $target
      $script:registrationBaseline=Registration-Snapshot
    }
  }
  foreach($crash in @(1,2,8,17,18)) {
    Case ('upgrade-interruption-recovery-'+$crash) {
      Install $target -Crash $crash
      Install $target; Assert-Payload $target
      Assert-True ((Get-FileHash -LiteralPath $personal -Algorithm SHA256).Hash -eq $personalHash) 'Interrupted upgrade lost a personal file.'
    }
  }
  Case 'locked-file-rejects-upgrade-and-uninstall-then-retries' {
    $baseline=Snapshot $target
    $held=[IO.File]::Open((Join-Path $target 'flutter_windows.dll'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
    try {
      Run-Process $setupPath ('/S /D='+$target) @(2) | Out-Null
      Uninstall $target $false
    } finally { $held.Dispose() }
    Assert-Snapshot $target $baseline
    Install $target; Assert-Payload $target
  }
  Case 'read-only-file-rejects-upgrade-and-uninstall-then-retries' {
    $path=Join-Path $target 'jianzhang.exe'; $attributes=[IO.File]::GetAttributes($path)
    [IO.File]::SetAttributes($path,($attributes -bor [IO.FileAttributes]::ReadOnly))
    try {
      Run-Process $setupPath ('/S /D='+$target) @(2) | Out-Null
      Uninstall $target $false
    } finally { [IO.File]::SetAttributes($path,$attributes) }
    Assert-Payload $target
  }
  Case 'uninstall-preserves-ledger-and-unowned-files' {
    Uninstall $target; Assert-Registration ''
    Assert-True ((Get-FileHash -LiteralPath $ledgerMarker -Algorithm SHA256).Hash -eq $ledgerHash) 'Uninstall changed the external ledger.'
    Assert-True ((Get-FileHash -LiteralPath $personal -Algorithm SHA256).Hash -eq $personalHash) 'Uninstall deleted a personal export.'
    Assert-True (!(Test-Path -LiteralPath (Join-Path $target 'jianzhang.exe'))) 'Uninstall left the program.'
  }
  for($failure=1;$failure -le 17;$failure++) {
    $first=Qa-Child $qaPath ('first-failure-'+$RoundId+'-'+$failure)
    Case ('first-install-injected-failure-'+$failure) {
      Install $first -Failure $failure
      Assert-Registration ''
      Assert-True (!(Test-Path -LiteralPath (Join-Path $first 'jianzhang.exe'))) 'Failed first install exposed a partial app.'
      Install $first; Assert-Payload $first; Uninstall $first; Assert-Registration ''
    }
  }
  Case 'file-instead-of-install-directory-is-rejected' {
    $fileTarget=Qa-Child $qaPath ('destination-file-'+$RoundId) 'File'
    [IO.File]::WriteAllText($fileTarget,'preserve this owned fixture')
    $before=(Get-FileHash -LiteralPath $fileTarget -Algorithm SHA256).Hash
    Run-Process $setupPath ('/S /D='+$fileTarget) @(2) | Out-Null
    Assert-True ((Get-FileHash -LiteralPath $fileTarget -Algorithm SHA256).Hash -eq $before) 'Installer overwrote a destination file.'
  }
  Case 'unwritable-parent-directory-is-rejected' {
    $parent=Qa-Child $qaPath ('unwritable-parent-'+$RoundId)
    New-Item -ItemType Directory -Path $parent | Out-Null
    $originalAcl=Get-Acl -LiteralPath $parent
    $restrictedAcl=Get-Acl -LiteralPath $parent
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent().User
    $rule=[Security.AccessControl.FileSystemAccessRule]::new($identity,[Security.AccessControl.FileSystemRights]::Write,
      [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Deny)
    $restrictedAcl.AddAccessRule($rule)
    try {
      Set-Acl -LiteralPath $parent -AclObject $restrictedAcl
      Run-Process $setupPath ('/S /D='+(Qa-Child $parent 'app')) @(2) | Out-Null
      Assert-True (!(Test-Path -LiteralPath (Join-Path $parent 'app/jianzhang.exe'))) 'Installer wrote into a restricted parent.'
    } finally { Set-Acl -LiteralPath $parent -AclObject $originalAcl }
  }
  Assert-CurrentSources
  @{roundId=$RoundId;buildId=$BuildId;status='pass';startedAt=$startedAt;finishedAt=[DateTimeOffset]::UtcNow.ToString('o');qaInstaller=$setupPath;qaInstallerSha256=$delivery.sha256;provenanceSha256=$deliveryHash;releasePayloadSha256=$delivery.payload.sha256;cases=$cases.ToArray()} |
    ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Qa-Child $outputPath 'installer-results.json' 'File') -Encoding utf8
} catch {
  @{roundId=$RoundId;buildId=$BuildId;status='fail';startedAt=$startedAt;finishedAt=[DateTimeOffset]::UtcNow.ToString('o');error=$_.Exception.Message;completedCases=$cases.ToArray()} |
    ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Qa-Child $outputPath 'installer-results.json' 'File') -Encoding utf8
  throw
}
