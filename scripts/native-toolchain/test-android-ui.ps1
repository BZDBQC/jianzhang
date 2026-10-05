param(
  [Parameter(Mandatory=$true)][ValidateSet(26,29,33,35,36,37)][int]$Api,
  [Parameter(Mandatory=$true)][string]$OutputDirectory,
  [ValidatePattern('^emulator-[0-9]+$')][string]$Serial='emulator-5554',
  [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._+-]{0,79}$')][string]$BuildId='development-v2',
  [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._+-]{0,79}$')][string]$RoundId=('android-ui-'+[Guid]::NewGuid().ToString('N'))
)
$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $workspace 'scripts/native-toolchain/source-contract.ps1')
$output=Assert-WorkspacePath -Workspace $workspace -Path $OutputDirectory -PathType Directory -AllowMissing
if (!$output.StartsWith((Join-Path $workspace '.qa/android-'),[StringComparison]::OrdinalIgnoreCase)) { throw 'Android QA output must be owned by this task.' }
if (Test-Path -LiteralPath $output) { throw 'Evidence output already exists; choose a new path to retain previous results.' }
New-Item -ItemType Directory -Path $output -ErrorAction Stop | Out-Null
$output=Assert-WorkspacePath -Workspace $workspace -Path $output -PathType Directory
$adb=Join-Path $workspace '.tools/android-sdk/platform-tools/adb.exe'
$sequence=0
$steps=[Collections.Generic.List[object]]::new()
$remotePrefix='/sdcard/Download/jianzhang-qa-'+[Guid]::NewGuid().ToString('N')
$runToken=[Guid]::NewGuid().ToString('N').Substring(0,8)
function Adb([string[]]$Arguments) {
  $lines=@(& $adb -s $Serial @Arguments 2>&1)
  if ($LASTEXITCODE -ne 0) { throw "ADB $($Arguments -join ' ') failed: $($lines -join ' ')" }
  return $lines
}
function Read-Ui([string]$Name='state') {
  $script:sequence++
  $xmlFile=Join-Path $output ('{0:000}-{1}.xml' -f $script:sequence,$Name)
  Adb @('shell','uiautomator','dump',($remotePrefix+'.xml')) | Out-Null
  Adb @('pull',($remotePrefix+'.xml'),$xmlFile) | Out-Null
  [xml]$document=Get-Content -LiteralPath $xmlFile -Raw
  return $document.SelectNodes('//node')
}
function Capture([string]$Name) {
  Adb @('shell','screencap','-p',($remotePrefix+'.png')) | Out-Null
  Adb @('pull',($remotePrefix+'.png'),(Join-Path $output ($Name+'.png'))) | Out-Null
  $bytes=[IO.File]::ReadAllBytes((Join-Path $output ($Name+'.png')))
  if ($bytes.Length -lt 33 -or [BitConverter]::ToString($bytes,0,8) -ne '89-50-4E-47-0D-0A-1A-0A') { throw 'Screenshot is not a PNG image.' }
  $width=[BitConverter]::ToInt32([byte[]]@($bytes[19],$bytes[18],$bytes[17],$bytes[16]),0)
  $height=[BitConverter]::ToInt32([byte[]]@($bytes[23],$bytes[22],$bytes[21],$bytes[20]),0)
  $steps.Add(@{name=$Name;at=[DateTimeOffset]::UtcNow.ToString('o');width=$width;height=$height})
  if ($Name -like '*landscape' -and $width -le $height) { throw 'Device did not rotate into landscape.' }
}
function Tap-Node($Node) {
  if ($Node.bounds -notmatch '^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$') { throw 'UI node has invalid bounds.' }
  $x=[int](([int]$Matches[1]+[int]$Matches[3])/2)
  $y=[int](([int]$Matches[2]+[int]$Matches[4])/2)
  if ([int]$Matches[4]-[int]$Matches[2] -lt 35) { throw 'UI node is clipped; scroll it fully into view.' }
  Adb @('shell','input','tap',"$x","$y") | Out-Null
}
function Scroll-Viewport($Nodes,[switch]$Reverse) {
  $scroll=$Nodes | Where-Object {$_.class -eq 'android.widget.ScrollView' -and $_.scrollable -eq 'true'} | Select-Object -Last 1
  if (!$scroll -or $scroll.bounds -notmatch '^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$') { throw 'Scrollable viewport is missing.' }
  $center=[int](([int]$Matches[1]+[int]$Matches[3])/2)
  $bottom=[int]$Matches[4]-25
  $top=[int]$Matches[2]+30
  if ($bottom-$top -lt 80) { throw 'Scrollable viewport is too short.' }
  $distance=[int](($bottom-$top)/2)
  if ($Reverse) { $from=$top; $to=$top+$distance }
  else { $from=$bottom; $to=$bottom-$distance }
  Adb @('shell','input','swipe',"$center","$from","$center","$to",'350') | Out-Null
}
function Find-Node([string]$Pattern,[string]$Class='',[switch]$Scroll) {
  for ($attempt=0;$attempt -lt 7;$attempt++) {
    $nodes=@(Read-Ui 'find')
    $rawCandidates=@($nodes | Where-Object { $_.GetAttribute('content-desc') -match $Pattern -and (!$Class -or $_.class -eq $Class) })
    $candidates=@($rawCandidates | Where-Object { $_.bounds -match '\[(\d+),(\d+)\]\[(\d+),(\d+)\]' -and [int]$Matches[4]-[int]$Matches[2] -ge 70 })
    if ($candidates.Count -eq 1) { return $candidates[0] }
    if ($candidates.Count -gt 1) { throw "Ambiguous UI description: $Pattern" }
    if (!$Scroll) { break }
    Scroll-Viewport $nodes -Reverse:($rawCandidates.Count -gt 0)
  }
  throw "UI element is missing: $Pattern"
}
function Tap([string]$Pattern,[string]$Class='android.widget.Button',[switch]$Scroll) { Tap-Node (Find-Node $Pattern $Class -Scroll:$Scroll) }
function Fill($Node,[string]$Text) {
  Tap-Node $Node
  Adb @('shell','input','keyevent','123','67','67','67','67','67','67','67','67','67','67','67','67') | Out-Null
  Adb @('shell','input','text',$Text) | Out-Null
}
function Select-Category([string]$Parent,[string]$Child,[string]$ChildLabel='小类') {
  Tap '^大类(?:\n|$)' -Scroll
  Tap ('^'+[regex]::Escape($Parent)+'$') 'android.view.MenuItem'
  Tap ('^'+[regex]::Escape($ChildLabel)+'(?:\n|$)') -Scroll
  Tap ('^'+[regex]::Escape($Child)+'$') 'android.view.MenuItem'
}
function Save-Entry([string]$Type,[string]$Amount,[string]$Note) {
  Tap '^记一笔$'
  Tap ('^'+$Type+'$')
  $fields=@(Read-Ui 'amount') | Where-Object {$_.class -eq 'android.widget.EditText'}
  if (!$fields) { throw 'Amount editor is missing.' }
  Fill (@($fields)[0]) $Amount
  Capture ($Type+'-keyboard')
  Adb @('shell','input','keyevent','4') | Out-Null
  if ($Type -eq '支出') { Select-Category '餐饮' '午餐' }
  if ($Type -eq '收入') { Select-Category '工作收入' '工资' }
  if ($Type -eq '转账') {
    Tap '^转入账户(?:\n|$)' -Scroll
    Tap '^现金$' 'android.view.MenuItem'
    $fee=$null
    for ($attempt=0;$attempt -lt 5 -and !$fee;$attempt++) {
      $feeNodes=@(Read-Ui 'fee')
      $fee=$feeNodes | Where-Object {$_.class -eq 'android.widget.EditText' -and $_.text -in @('0','0.00') } | Select-Object -First 1
      if (!$fee) { Scroll-Viewport $feeNodes }
    }
    if (!$fee) { throw 'Transfer fee editor is missing.' }
    Fill $fee '0.25'
    Adb @('shell','input','keyevent','4') | Out-Null
    Select-Category '其他支出' '手续费' '手续费小类'
  }
  Find-Node '^保存账单$' 'android.widget.Button' -Scroll | Out-Null
  $noteField=@(Read-Ui 'note') | Where-Object {$_.class -eq 'android.widget.EditText' -and !$_.text} | Select-Object -Last 1
  if (!$noteField) { throw 'Note editor is missing.' }
  Fill $noteField $Note
  Adb @('shell','input','keyevent','4') | Out-Null
  Capture ($Type+'-before-save')
  Tap '^保存账单$' -Scroll
  Find-Node '^记一笔$' 'android.widget.Button' | Out-Null
  Capture ($Type+'-saved')
}
$started=[DateTimeOffset]::UtcNow.ToString('o')
$failure=$null
$original=@{}
foreach ($item in @(@('global','airplane_mode_on'),@('global','wifi_on'),@('global','mobile_data'),@('system','accelerometer_rotation'),@('system','user_rotation'))) {
  $original[$item[1]]=@(Adb @('shell','settings','get',$item[0],$item[1]))[0].Trim()
}
try {
  if ([int](@(Adb @('shell','getprop','ro.build.version.sdk'))[0]) -ne $Api) { throw 'Wrong Android API device.' }
  $manifestPath=Assert-WorkspacePath -Workspace $workspace -Path (Join-Path $workspace 'releases/android/release-manifest-2.0.0.json') -PathType File
  $sourcePath=Assert-WorkspacePath -Workspace $workspace -Path (Join-Path $workspace 'releases/android/source-manifest-2.0.0.json') -PathType File
  $manifest=Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  $source=Get-Content -LiteralPath $sourcePath -Raw | ConvertFrom-Json
  if ($manifest.schemaVersion -ne 2 -or $manifest.sourceSha256 -ne $source.sha256) { throw 'Verified release source identity is required.' }
  Assert-FileContract $source (Get-ClientSourceContract -Root (Join-Path $workspace 'clients/flutter') -Platform android) 'Android UI release sources'
  $expected=$manifest.sha256
  $manifestHash=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
  $sourceManifestHash=(Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
  $installed=@(Adb @('shell','pm','path','com.jianzhang.ledger'))
  if ($installed.Count -ne 1 -or $installed[0] -notmatch '^package:(/data/app/[^\r\n]+/base\.apk)$') { throw 'Single installed APK is required.' }
  $actual=(@(Adb @('shell','sha256sum',$Matches[1]))[0]).Split(' ')[0]
  if ($actual -ne $expected) { throw 'Installed APK is not the recorded production release.' }
  Adb @('shell','settings','put','global','airplane_mode_on','1') | Out-Null
  Adb @('shell','svc','wifi','disable') | Out-Null
  Adb @('shell','svc','data','disable') | Out-Null
  Adb @('shell','settings','put','system','accelerometer_rotation','0') | Out-Null
  Adb @('shell','settings','put','system','user_rotation','0') | Out-Null
  Adb @('shell','am','force-stop','com.jianzhang.ledger') | Out-Null
  Adb @('shell','am','start','-W','-n','com.jianzhang.ledger/.MainActivity') | Set-Content (Join-Path $output 'launch.log')
  Find-Node '收支概览' 'android.view.View' | Out-Null
  $base=(@(Read-Ui 'initial') | Where-Object {$_.GetAttribute('content-desc') -match '本机已保存 · (\d+) 笔账单'} | Select-Object -First 1).GetAttribute('content-desc')
  if ($base -notmatch '本机已保存 · (\d+) 笔账单') { throw 'Initial ledger count is missing.' }
  $baseCount=[int]$Matches[1]
  Capture 'home-offline'
  Save-Entry '支出' '12.34' ('QA'+$Api+'-expense-'+$runToken)
  Save-Entry '收入' '50.00' ('QA'+$Api+'-income-'+$runToken)
  Save-Entry '转账' '10.00' ('QA'+$Api+'-transfer-'+$runToken)
  Adb @('shell','am','force-stop','com.jianzhang.ledger') | Out-Null
  Adb @('shell','am','start','-W','-n','com.jianzhang.ledger/.MainActivity') | Out-Null
  $nodes=@(Read-Ui 'restart')
  $countText=($nodes | Where-Object {$_.GetAttribute('content-desc') -match '本机已保存 · (\d+) 笔账单'} | Select-Object -First 1).GetAttribute('content-desc')
  if ($countText -notmatch '本机已保存 · (\d+) 笔账单' -or [int]$Matches[1] -ne $baseCount+3) { throw 'Offline restart did not retain all three transactions.' }
  Capture 'home-restart'
  Tap '^账单\n'
  $billText=''
  for($position=0;$position -lt 7;$position++) {
    $nodes=@(Read-Ui 'bills')
    $billText+=($nodes | ForEach-Object {$_.GetAttribute('content-desc')}) -join "`n"
    Capture ('bills-position-'+$position)
    $allFound=$true
    foreach($type in @('expense','income','transfer')) { if (!$billText.Contains('QA'+$Api+'-'+$type+'-'+$runToken)) { $allFound=$false } }
    if($allFound) { break }
    Scroll-Viewport $nodes
  }
  if(!$allFound) { throw 'One or more saved notes were absent after traversing the bills viewport.' }
  Tap '^首页\n'
  Adb @('shell','settings','put','system','user_rotation','1') | Out-Null
  Start-Sleep -Milliseconds 350
  Read-Ui 'home-landscape-idle' | Out-Null
  Capture 'home-landscape'
  Adb @('shell','settings','put','system','user_rotation','0') | Out-Null
  Start-Sleep -Milliseconds 350
  Tap '^记一笔$'
  Adb @('shell','input','text','99.99') | Out-Null
  Adb @('shell','input','keyevent','4') | Out-Null
  Find-Node '^保存账单$' 'android.widget.Button' -Scroll | Out-Null
  Adb @('shell','settings','put','system','user_rotation','1') | Out-Null
  Start-Sleep -Milliseconds 350
  Read-Ui 'draft-landscape-idle' | Out-Null
  Capture 'draft-landscape'
  Adb @('shell','settings','put','system','user_rotation','0') | Out-Null
  Start-Sleep -Milliseconds 350
  Adb @('shell','input','keyevent','4') | Out-Null
  Find-Node '^记一笔$' 'android.widget.Button' | Out-Null
  Capture 'back-dismissed-draft'
  Assert-FileContract $source (Get-ClientSourceContract -Root (Join-Path $workspace 'clients/flutter') -Platform android) 'Android UI sources after testing'
  if ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifestHash) { throw 'Release manifest changed during UI testing.' }
  if ((Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sourceManifestHash) { throw 'Source manifest changed during UI testing.' }
} catch { $failure=$_.Exception.Message; throw }
finally {
  $cleanupErrors=[Collections.Generic.List[string]]::new()
  function Cleanup([scriptblock]$Action) { try { & $Action } catch { $cleanupErrors.Add($_.Exception.Message) } }
  Cleanup { Adb @('logcat','-d','-b','main','-b','system','-v','epoch') | Set-Content (Join-Path $output 'device.log') }
  foreach($item in @(@('global','airplane_mode_on'),@('system','accelerometer_rotation'),@('system','user_rotation'))) {
    $value=$original[$item[1]]
    if ($value -eq 'null') { Cleanup { Adb @('shell','settings','delete',$item[0],$item[1]) | Out-Null } }
    else { Cleanup { Adb @('shell','settings','put',$item[0],$item[1],$value) | Out-Null } }
  }
  Cleanup { Adb @('shell','svc','wifi',$(if($original.wifi_on -eq '0'){'disable'}else{'enable'})) | Out-Null }
  Cleanup { Adb @('shell','svc','data',$(if($original.mobile_data -eq '0'){'disable'}else{'enable'})) | Out-Null }
  Cleanup { Adb @('shell','rm','-f',($remotePrefix+'.xml'),($remotePrefix+'.png')) | Out-Null }
  @{buildId=$BuildId;roundId=$RoundId;api=$Api;serial=$Serial;mode='release';apkSha256=$actual;sourceSha256=$source.sha256;releaseManifestSha256=$manifestHash;sourceManifestSha256=$sourceManifestHash;runToken=$runToken;startedAt=$started;finishedAt=[DateTimeOffset]::UtcNow.ToString('o');steps=$steps.ToArray();status=$(if($failure -or $cleanupErrors.Count){'failed'}else{'passed'});error=$failure;cleanupErrors=$cleanupErrors.ToArray();baselineCount=$baseCount;restoredSettings=$original} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $output 'evidence.json') -Encoding utf8
  if (!$failure -and $cleanupErrors.Count) { throw ($cleanupErrors -join '; ') }
}
