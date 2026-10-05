param(
  [Parameter(Mandatory=$true)][string]$ProviderManifest,
  [Parameter(Mandatory=$true)][string]$OutputDirectory,
  [Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._+-]{0,79}$')][string]$BuildId,
  [Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._+-]{0,79}$')][string]$RoundId,
  [ValidatePattern('^emulator-[0-9]+$')][string]$Serial='emulator-5554',
  [string]$Python=(Get-Command python.exe -ErrorAction Stop).Source
)
$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $PSScriptRoot 'source-contract.ps1')
$output=Assert-WorkspacePath -Workspace $workspace -Path $OutputDirectory -PathType Directory -AllowMissing
if (!$output.StartsWith((Join-Path $workspace '.qa/android-'),[StringComparison]::OrdinalIgnoreCase)) { throw 'An owned Android QA output path is required.' }
if (Test-Path -LiteralPath $output) { throw 'Evidence already exists; choose another output path.' }
New-Item -ItemType Directory -Path $output | Out-Null
$output=Assert-WorkspacePath -Workspace $workspace -Path $output -PathType Directory
$adb=Join-Path $workspace '.tools/android-sdk/platform-tools/adb.exe'
$prefix='/data/local/tmp/jianzhang-saf-'+[Guid]::NewGuid().ToString('N')
$remoteFiles=[Collections.Generic.List[string]]::new()
$commands=[Collections.Generic.List[object]]::new()
$cases=[Collections.Generic.List[object]]::new()
$sequence=0
$failure=$null
$started=[DateTimeOffset]::UtcNow.ToString('o')
$oldPythonEncoding=[Environment]::GetEnvironmentVariable('PYTHONIOENCODING','Process')
function Artifact([string]$Name) {
  return Assert-WorkspacePath -Workspace $workspace -Path (Join-Path $output $Name) -PathType File -AllowMissing
}
function Adb([string[]]$Arguments,[switch]$AllowFailure) {
  $at=[DateTimeOffset]::UtcNow.ToString('o')
  $lines=@(& $adb -s $Serial @Arguments 2>&1 | ForEach-Object { $_.ToString() })
  $script:lastAdbExit=$LASTEXITCODE
  $commands.Add(@{at=$at;finishedAt=[DateTimeOffset]::UtcNow.ToString('o');arguments=@('-s',$Serial)+$Arguments;exitCode=$script:lastAdbExit;output=$lines})
  if ($script:lastAdbExit -ne 0 -and !$AllowFailure) { throw "ADB failed: $($Arguments -join ' '): $($lines -join ' ')" }
  return $lines
}
function Read-Ui([string]$Name) {
  for ($attempt=0;$attempt -lt 4;$attempt++) {
    $script:sequence++
    $remote=$prefix+'-'+$script:sequence+'.xml'
    $remoteFiles.Add($remote)
    $dump=@(Adb @('shell','uiautomator','dump',$remote) -AllowFailure)
    if ($script:lastAdbExit -eq 0 -and $dump -match 'UI hierchary dumped to:') {
      $path=Artifact ('{0:000}-{1}.xml' -f $script:sequence,$Name)
      Adb @('pull',$remote,$path) | Out-Null
      [xml]$document=Get-Content -LiteralPath $path -Raw
      return $document.SelectNodes('//node')
    }
    Start-Sleep -Milliseconds 400
  }
  throw 'UI did not provide a fresh hierarchy.'
}
function Find-Node([string]$Pattern,[string]$Name='find') {
  for ($attempt=0;$attempt -lt 4;$attempt++) {
    $node=@(Read-Ui $Name) | Where-Object { $_.GetAttribute('content-desc') -match $Pattern -or $_.GetAttribute('text') -match $Pattern } | Select-Object -First 1
    if ($node) { return $node }
    Start-Sleep -Milliseconds 250
  }
  throw "Missing UI: $Pattern"
}
function Find-SearchEditor {
  for ($attempt=0;$attempt -lt 4;$attempt++) {
    $fields=@(Read-Ui 'valid-search-editor') | Where-Object {
      $_.class -in @('android.widget.EditText','android.widget.AutoCompleteTextView') -and
      $_.GetAttribute('resource-id') -in @('android:id/search_src_text','com.android.documentsui:id/search_src_text') -and
      $_.enabled -eq 'true' -and $_.clickable -eq 'true' -and
      $_.GetAttribute('visible-to-user') -ne 'false' -and
      $_.bounds -match '^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$' -and
      [long]$Matches[3] -gt [long]$Matches[1] -and [long]$Matches[4] -gt [long]$Matches[2]
    }
    $fields=@($fields)
    if ($fields.Count -eq 1) { return $fields[0] }
    if ($fields.Count -gt 1) { throw 'System file search editor is ambiguous.' }
    Start-Sleep -Milliseconds 250
  }
  throw 'System file search editor is missing.'
}
function Find-ExactDocument([string]$BaseName) {
  for ($attempt=0;$attempt -lt 4;$attempt++) {
    $files=@(Read-Ui 'valid-search-result') | Where-Object {
      $_.GetAttribute('text') -ceq $BaseName -and
      $_.class -notin @('android.widget.EditText','android.widget.AutoCompleteTextView') -and
      $_.GetAttribute('resource-id') -in @('android:id/title','com.android.documentsui:id/title') -and
      $_.enabled -eq 'true'
    }
    $files=@($files)
    if ($files.Count -eq 1) { return $files[0] }
    if ($files.Count -gt 1) { throw 'Exact system search document is ambiguous.' }
    Start-Sleep -Milliseconds 250
  }
  throw "Exact system search document was not found: $BaseName"
}
function Search-Document([string]$BaseName) {
  if ($BaseName -notmatch '^jianzhang-valid-[0-9a-f]{32}\.json$') { throw 'Unexpected QA document basename.' }
  Tap-Node (Find-Node '^(Search|搜索)$' 'valid-search-toolbar')
  $editor=Find-SearchEditor
  Tap-Node $editor
  Adb @('shell','input','keyevent','123') | Out-Null
  for ($delete=0;$delete -lt $editor.GetAttribute('text').Length;$delete++) {
    Adb @('shell','input','keyevent','67') | Out-Null
  }
  Adb @('shell','input','text',$BaseName) | Out-Null
  Adb @('shell','input','keyevent','66') | Out-Null
  return Find-ExactDocument $BaseName
}
function Tap-Node($Node) {
  if ($Node.bounds -notmatch '^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$') { throw 'Invalid target bounds.' }
  $x=[int](([int]$Matches[1]+[int]$Matches[3])/2)
  $y=[int](([int]$Matches[2]+[int]$Matches[4])/2)
  Adb @('shell','input','tap',"$x","$y") | Out-Null
}
function Capture([string]$Name) {
  $remote=$prefix+'-'+$Name+'.png'
  $remoteFiles.Add($remote)
  Adb @('shell','screencap','-p',$remote) | Out-Null
  $path=Artifact ($Name+'.png')
  Adb @('pull',$remote,$path) | Out-Null
  $bytes=[IO.File]::ReadAllBytes($path)
  if ($bytes.Length -lt 33 -or [BitConverter]::ToString($bytes,0,8) -ne '89-50-4E-47-0D-0A-1A-0A') { throw 'Screenshot is not a PNG image.' }
}
function Installed-Sha([string]$Package) {
  $paths=@(Adb @('shell','pm','path',$Package))
  if ($paths.Count -ne 1 -or $paths[0] -notmatch '^package:(/data/app/[^\r\n]+/base\.apk)$') { throw "A single installed APK is required: $Package" }
  return (@(Adb @('shell','sha256sum',$Matches[1]))[0]).Split(' ')[0]
}
function Open-Picker {
  Adb @('shell','am','start','-W','-n','com.jianzhang.ledger/.MainActivity') | Out-Null
  Tap-Node (Find-Node '^更多\n' 'more-navigation')
  Tap-Node (Find-Node '^数据与设置$' 'data-page')
  Tap-Node (Find-Node '^恢复 JSON 备份$' 'restore')
  return Read-Ui 'picker'
}
function Get-PickerBounds($Node) {
  if ($Node.GetAttribute('bounds') -notmatch '^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$') { return $null }
  $box=@{left=[long]$Matches[1];top=[long]$Matches[2];right=[long]$Matches[3];bottom=[long]$Matches[4]}
  if ($box.right -le $box.left -or $box.bottom -le $box.top) { return $null }
  return $box
}
function Test-PickerContains($Outer,$Inner) {
  return $null -ne $Outer -and $null -ne $Inner -and $Inner.left -ge $Outer.left -and $Inner.top -ge $Outer.top -and $Inner.right -le $Outer.right -and $Inner.bottom -le $Outer.bottom
}
function Test-PickerVisible($Node) {
  for ($ancestor=$Node;$ancestor -is [Xml.XmlElement];$ancestor=$ancestor.ParentNode) {
    if ($ancestor.GetAttribute('enabled') -eq 'false' -or $ancestor.GetAttribute('visible-to-user') -eq 'false') { return $false }
  }
  return $true
}
function Get-OpenPickerRoots($Nodes) {
  $open=[Collections.Generic.List[object]]::new()
  foreach ($list in $Nodes) {
    if ($list.GetAttribute('resource-id') -notin @('com.android.documentsui:id/roots_list','android:id/roots_list') -or !(Test-PickerVisible $list)) { continue }
    $drawer=$list.ParentNode
    while ($drawer -is [Xml.XmlElement] -and $drawer.GetAttribute('resource-id') -notin @('com.android.documentsui:id/drawer_roots','android:id/drawer_roots')) { $drawer=$drawer.ParentNode }
    if ($drawer -isnot [Xml.XmlElement] -or !(Test-PickerVisible $drawer)) { continue }
    $listBounds=Get-PickerBounds $list
    $drawerBounds=Get-PickerBounds $drawer
    if (Test-PickerContains $drawerBounds $listBounds) { $open.Add(@{node=$list;bounds=$listBounds;drawerBounds=$drawerBounds}) }
  }
  if ($open.Count -gt 1) { throw 'Visible system roots drawer is ambiguous.' }
  if ($open.Count -eq 1) { return $open[0] }
  return $null
}
function Get-QAProviderRow($Roots) {
  $titles=@($Roots.node.SelectNodes('.//node') | Where-Object {
    $_.GetAttribute('text') -ceq '简账 QA 故障文件' -and
    $_.class -notin @('android.widget.EditText','android.widget.AutoCompleteTextView') -and
    $_.GetAttribute('resource-id') -in @('android:id/title','com.android.documentsui:id/title') -and
    $_.enabled -eq 'true' -and (Test-PickerVisible $_) -and (Test-PickerContains $Roots.bounds (Get-PickerBounds $_))
  })
  if ($titles.Count -gt 1) { throw 'Exact QA provider inside roots drawer is ambiguous.' }
  if (!$titles.Count) { return $null }
  $row=$titles[0]
  while ($row -is [Xml.XmlElement] -and $row -ne $Roots.node -and $row.GetAttribute('clickable') -ne 'true') { $row=$row.ParentNode }
  if ($row -isnot [Xml.XmlElement] -or $row -eq $Roots.node -or !(Test-PickerVisible $row)) { return $null }
  $rowBounds=Get-PickerBounds $row
  if (!(Test-PickerContains $Roots.bounds $rowBounds) -or !(Test-PickerContains $rowBounds (Get-PickerBounds $titles[0]))) { return $null }
  return $row
}
function Open-Import([string]$Document) {
  $nodes=@(Open-Picker)
  if (!(Get-OpenPickerRoots $nodes)) {
    $drawer=Find-Node '^(Show roots|显示根目录)$' 'provider-drawer'
    $drawerTargets=@($drawer.OwnerDocument.SelectNodes('//node') | Where-Object {
      ($_.GetAttribute('content-desc') -cmatch '^(Show roots|显示根目录)$' -or $_.GetAttribute('text') -cmatch '^(Show roots|显示根目录)$') -and
      $_.class -in @('android.widget.ImageButton','android.widget.Button') -and $_.enabled -eq 'true' -and $_.clickable -eq 'true' -and
      (Test-PickerVisible $_) -and $null -ne (Get-PickerBounds $_)
    })
    if ($drawerTargets.Count -ne 1) { throw 'System roots drawer is ambiguous or unavailable.' }
    Tap-Node $drawerTargets[0]
    $nodes=@(Read-Ui 'provider-roots-opened')
  }
  # Always confirm the actual provider root before considering document titles.
  # Drawer overlays leave enabled backing documents in the UI hierarchy.
  $row=$null
  for ($attempt=0;$attempt -lt 4;$attempt++) {
    $roots=Get-OpenPickerRoots $nodes
    if ($roots) { $row=Get-QAProviderRow $roots }
    if ($row) { break }
    if ($attempt -lt 3) { Start-Sleep -Milliseconds 250; $nodes=@(Read-Ui 'provider-roots') }
  }
  if (!$row) { throw 'Exact QA provider in a visible roots drawer was not found.' }
  Tap-Node $row
  for ($attempt=0;$attempt -lt 4;$attempt++) {
    $documentNode=Find-ExactDocument $Document
    if (!(Get-OpenPickerRoots @($documentNode.OwnerDocument.SelectNodes('//node'))) -and (Test-PickerVisible $documentNode) -and $null -ne (Get-PickerBounds $documentNode)) { return $documentNode }
    Start-Sleep -Milliseconds 250
  }
  throw 'Exact provider document is not visible or is obscured by the system roots drawer.'
}
function Snapshot-Database([string]$Name) {
  # Stopping this QA-owned app makes the DB and optional WAL a consistent copy.
  # Compare SQL content: closing SQLite can checkpoint/delete WAL without a
  # domain change, so file-layout SHA equality is deliberately not asserted.
  Adb @('shell','am','force-stop','com.jianzhang.ledger') | Out-Null
  $db=Artifact ($Name+'.sqlite')
  foreach($suffix in @('','-wal','-shm')) {
    $source='/data/data/com.jianzhang.ledger/files/jianzhang.sqlite'+$suffix
    Adb @('shell','su','0','test','-f',$source) -AllowFailure | Out-Null
    if ($script:lastAdbExit -eq 1 -and $suffix) { continue }
    if ($script:lastAdbExit -ne 0) { throw 'Cannot inspect the QA-owned database.' }
    $remote=$prefix+'-'+$Name+'.sqlite'+$suffix
    $remoteFiles.Add($remote)
    Adb @('shell','su','0','cp',$source,$remote) | Out-Null
    # This task's new tmp copy must be readable by adb shell. Never chmod the
    # private source database or any pre-existing file.
    Adb @('shell','su','0','chmod','0644',$remote) | Out-Null
    Adb @('pull',$remote,(Artifact ($Name+'.sqlite'+$suffix))) | Out-Null
  }
  $code=@'
import hashlib,json,pathlib,sqlite3,sys
c=sqlite3.connect(pathlib.Path(sys.argv[1]).as_uri()+'?mode=ro',uri=True)
result={'integrityCheck':c.execute('pragma integrity_check').fetchall(),'userVersion':c.execute('pragma user_version').fetchone()[0],'tables':{}}
def quote(name): return '"'+name.replace('"','""')+'"'
for table,schema in c.execute("select name,sql from sqlite_master where type='table' and name not like 'sqlite\\_%' escape '\\' order by name").fetchall():
    columns=c.execute('pragma table_info('+quote(table)+')').fetchall()
    digest=hashlib.sha256(); count=0
    order=','.join(quote(column[1]) for column in columns)
    for row in c.execute('select * from '+quote(table)+' order by '+order):
        digest.update(json.dumps(row,ensure_ascii=False,separators=(',',':')).encode('utf-8')+b'\n'); count+=1
    result['tables'][table]={'schema':schema,'columns':columns,'rows':count,'sha256':digest.hexdigest()}
c.close()
print(json.dumps(result,ensure_ascii=False,sort_keys=True,separators=(',',':')))
'@
  $json=@(& $Python -c $code $db)
  if ($LASTEXITCODE -ne 0) { throw 'Read-only database verification failed.' }
  $json -join "`n" | Set-Content -LiteralPath (Artifact ($Name+'-sql.json')) -Encoding utf8
  $state=($json -join "`n") | ConvertFrom-Json
  if ($state.integrityCheck[0][0] -ne 'ok') { throw 'SQLite integrity check failed.' }
  return $json -join "`n"
}
try {
  $env:PYTHONIOENCODING='utf-8'
  if (@(Adb @('shell','getprop','ro.boot.qemu.avd_name'))[0] -ne 'Jianzhang_API35') { throw 'Only the owned fixed API35 emulator is supported.' }
  if (@(Adb @('shell','su','0','id'))[0] -notmatch '^uid=0') { throw 'Read-only QA database verification needs the userdebug emulator su capability.' }
  $releasePath=Assert-WorkspacePath -Workspace $workspace -Path (Join-Path $workspace 'releases/android/release-manifest-2.0.0.json') -PathType File
  $sourcePath=Assert-WorkspacePath -Workspace $workspace -Path (Join-Path $workspace 'releases/android/source-manifest-2.0.0.json') -PathType File
  $providerPath=Assert-WorkspacePath -Workspace $workspace -Path $ProviderManifest -PathType File
  $release=Get-Content -LiteralPath $releasePath -Raw | ConvertFrom-Json
  $source=Get-Content -LiteralPath $sourcePath -Raw | ConvertFrom-Json
  $provider=Get-Content -LiteralPath $providerPath -Raw | ConvertFrom-Json
  $releaseApk=Assert-WorkspacePath -Workspace $workspace -Path (Join-Path $workspace 'releases/android/jianzhang-2.0.0.apk') -PathType File
  $providerApk=Assert-WorkspacePath -Workspace $workspace -Path $provider.apk -PathType File
  $fixturePath=Assert-WorkspacePath -Workspace $workspace -Path (Join-Path $workspace 'tests/fixtures/native-ledger-v1.json') -PathType File
  $releaseHash=(Get-FileHash $releasePath -Algorithm SHA256).Hash.ToLowerInvariant()
  $sourceHash=(Get-FileHash $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
  $providerHash=(Get-FileHash $providerPath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($release.schemaVersion -ne 2 -or $release.sourceSha256 -ne $source.sha256) { throw 'Release source identity mismatch.' }
  Assert-FileContract $source (Get-ClientSourceContract -Root (Join-Path $workspace 'clients/flutter') -Platform android) 'SAF release client sources'
  $providerRoot=Join-Path $PSScriptRoot 'android-provider-qa'
  if ($provider.schemaVersion -ne 1 -or !$provider.qaOnly -or $provider.package -ne 'com.jianzhang.qa.faultprovider') { throw 'Only the isolated QA provider is allowed.' }
  Assert-FileContract $provider.source (Get-FileListContract -Root $providerRoot -Files @(Get-TreeFiles -Root $providerRoot)) 'SAF provider sources'
  if ((Get-FileHash $fixturePath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $provider.legacyLedgerFixtureSha256) { throw 'QA provider legacy fixture changed.' }
  if ((Get-FileHash $releaseApk -Algorithm SHA256).Hash.ToLowerInvariant() -ne $release.sha256 -or (Get-FileHash $providerApk -Algorithm SHA256).Hash.ToLowerInvariant() -ne $provider.sha256) { throw 'Local delivery APK identity mismatch.' }
  $installed=Installed-Sha 'com.jianzhang.ledger'
  if ($installed -ne $release.sha256 -or (Installed-Sha 'com.jianzhang.qa.faultprovider') -ne $provider.sha256) { throw 'Installed artifact identity mismatch.' }
  Adb @('shell','am','start','-W','-n','com.jianzhang.ledger/.MainActivity') | Out-Null
  Find-Node '本机已保存 · [0-9]+ 笔账单' 'initial-home' | Out-Null
  $baseline=Snapshot-Database 'baseline'
  $validName='jianzhang-valid-'+[Guid]::NewGuid().ToString('N')+'.json'
  $validRemote='/sdcard/Download/'+$validName
  $remoteFiles.Add($validRemote)
  Adb @('push',$fixturePath,$validRemote) | Out-Null
  Open-Picker | Out-Null
  Tap-Node (Find-Node '^(Show roots|显示根目录)$' 'valid-picker-drawer')
  Tap-Node (Find-Node '^(Downloads|下载|下载内容)$' 'valid-downloads')
  Tap-Node (Search-Document $validName)
  Find-Node '确认恢复备份' 'valid-preview-title' | Out-Null
  $fixture=Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json
  Find-Node ([regex]::Escape("$(@($fixture.transactions).Count) 笔账单")) 'valid-preview-count' | Out-Null
  Capture 'valid-preview'
  Tap-Node (Find-Node '^取消$' 'valid-preview-cancel')
  Find-Node '^恢复 JSON 备份$' 'valid-cancelled' | Out-Null
  $validCache=@(Adb @('shell','su','0','find','/data/data/com.jianzhang.ledger/cache','-maxdepth','1','-name','jianzhang-import-*'))
  if ($validCache.Count) { throw 'Cancelled valid preview retained import cache.' }
  if ((Snapshot-Database 'valid-cancel-after') -ne $baseline) { throw 'Cancelling the valid preview changed domain data.' }
  $cases.Add(@{name='valid-preview-cancel';at=[DateTimeOffset]::UtcNow.ToString('o');previewTransactions=@($fixture.transactions).Count;domainUnchanged=$true;cacheCleared=$true})
  foreach($item in @(@('reliable','可靠管道错误.json'),@('corrupt','损坏 JSON.json'))) {
    $node=Open-Import $item[1]
    Tap-Node $node
    $errorNode=Find-Node '导入未完成：' ($item[0]+'-error')
    $message=$errorNode.GetAttribute('content-desc')+' '+$errorNode.GetAttribute('text')
    if ($message -match 'PlatformException|FILE_IO|Remote error|/data/|StackTrace') { throw 'The user-visible failure exposes implementation details.' }
    Capture ($item[0]+'-error')
    $rejectedCache=@(Adb @('shell','su','0','find','/data/data/com.jianzhang.ledger/cache','-maxdepth','1','-name','jianzhang-import-*'))
    if ($rejectedCache.Count) { throw 'Rejected file left an app-owned import cache file.' }
    if ((Snapshot-Database ($item[0]+'-after')) -ne $baseline) { throw 'Rejected file changed domain data.' }
    $cases.Add(@{name=$item[0];at=[DateTimeOffset]::UtcNow.ToString('o');domainUnchanged=$true;userMessage=$message})
  }
  $node=Open-Import '停滞管道.json'
  $stallStart=[DateTimeOffset]::UtcNow
  Tap-Node $node
  Find-Node '正在处理文件' 'stall-processing' | Out-Null
  Tap-Node (Find-Node '^首页\n' 'stall-home-navigation')
  Find-Node '本机已保存 · [0-9]+ 笔账单' 'stall-home-responsive' | Out-Null
  Capture 'stall-home-responsive'
  $pendingCache=@(Adb @('shell','su','0','find','/data/data/com.jianzhang.ledger/cache','-maxdepth','1','-name','jianzhang-import-*'))
  if (!$pendingCache.Count) { throw 'No actual pending app-owned import file exists before cancellation.' }
  $beforeBack=[DateTimeOffset]::UtcNow
  Adb @('shell','input','keyevent','4') | Out-Null
  $deadline=$beforeBack.AddSeconds(5)
  $polls=@()
  do {
    $files=@(Adb @('shell','su','0','find','/data/data/com.jianzhang.ledger/cache','-maxdepth','1','-name','jianzhang-import-*'))
    $now=[DateTimeOffset]::UtcNow
    $polls+=@{at=$now.ToString('o');files=$files}
    if (!$files.Count) { break }
    Start-Sleep -Milliseconds 100
  } while ($now -lt $deadline)
  $cancel=@{name='stalled';startedAt=$stallStart.ToString('o');pendingCacheBeforeBack=$pendingCache;backAt=$beforeBack.ToString('o');clearedAt=$now.ToString('o');afterBackCleanupMs=($now-$beforeBack).TotalMilliseconds;sinceSelectionMs=($now-$stallStart).TotalMilliseconds;polls=$polls;producerMaxHoldMs=30000;scope='app-owned reader/cache cancellation; producer deliberately ignores cancellation; UI dump duration is not frame timing'}
  $cancel | ConvertTo-Json -Depth 5 | Set-Content (Artifact 'cancellation.json') -Encoding utf8
  if ($files.Count -or ($now-$beforeBack).TotalMilliseconds -gt 5000 -or ($now-$stallStart).TotalMilliseconds -ge 30000) { throw 'App cleanup was not proven within five seconds and before the producer timeout.' }
  if ((Snapshot-Database 'stall-after') -ne $baseline) { throw 'Cancelled file changed domain data.' }
  $cases.Add($cancel)
  Adb @('shell','am','start','-W','-n','com.jianzhang.ledger/.MainActivity') | Out-Null
  Find-Node '本机已保存 · [0-9]+ 笔账单' 'reopened-home' | Out-Null
  Capture 'reopened-home'
  Assert-FileContract $source (Get-ClientSourceContract -Root (Join-Path $workspace 'clients/flutter') -Platform android) 'SAF client sources after tests'
  Assert-FileContract $provider.source (Get-FileListContract -Root $providerRoot -Files @(Get-TreeFiles -Root $providerRoot)) 'SAF provider sources after tests'
  if ((Get-FileHash $releasePath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $releaseHash -or (Get-FileHash $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sourceHash -or (Get-FileHash $providerPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $providerHash) { throw 'Artifact manifests changed during tests.' }
  if ((Get-FileHash $releaseApk -Algorithm SHA256).Hash.ToLowerInvariant() -ne $release.sha256 -or (Get-FileHash $providerApk -Algorithm SHA256).Hash.ToLowerInvariant() -ne $provider.sha256 -or (Get-FileHash $fixturePath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $provider.legacyLedgerFixtureSha256) { throw 'Delivery APK or shared fixture changed during tests.' }
  if ((Installed-Sha 'com.jianzhang.ledger') -ne $installed -or (Installed-Sha 'com.jianzhang.qa.faultprovider') -ne $provider.sha256) { throw 'Installed artifacts changed during tests.' }
} catch { $failure=$_.Exception.Message; throw }
finally {
  $cleanup=[Collections.Generic.List[string]]::new()
  try { Adb @('logcat','-d','-b','main','-b','system','-v','epoch') | Set-Content (Artifact 'device.log') } catch { $cleanup.Add($_.Exception.Message) }
  foreach($remote in $remoteFiles) { try { Adb @('shell','rm','-f',$remote) | Out-Null } catch { $cleanup.Add($_.Exception.Message) } }
  [Environment]::SetEnvironmentVariable('PYTHONIOENCODING',$oldPythonEncoding,'Process')
  $commands.ToArray() | ConvertTo-Json -Depth 5 | Set-Content (Artifact 'commands.json') -Encoding utf8
  @{schemaVersion=1;buildId=$BuildId;roundId=$RoundId;serial=$Serial;mode='release';apkSha256=$installed;sourceSha256=$source.sha256;releaseManifestSha256=$releaseHash;sourceManifestSha256=$sourceHash;providerApkSha256=$provider.sha256;providerManifestSha256=$providerHash;startedAt=$started;finishedAt=[DateTimeOffset]::UtcNow.ToString('o');cases=$cases.ToArray();status=$(if($failure -or $cleanup.Count){'failed'}else{'passed'});error=$failure;cleanupErrors=$cleanup.ToArray()} | ConvertTo-Json -Depth 6 | Set-Content (Artifact 'evidence.json') -Encoding utf8
  if (!$failure -and $cleanup.Count) { throw ($cleanup -join '; ') }
}
