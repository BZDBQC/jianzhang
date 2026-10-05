$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$helper=Join-Path $workspace 'scripts/native-toolchain/test-android-saf.ps1'
$errors=$null
$tokens=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($helper,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'SAF helper parse failed.' }
$resultRoot=Join-Path $workspace ('.qa/android-saf-pure-fixtures-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $resultRoot | Out-Null
$passed=[Collections.Generic.List[string]]::new()
$failed=[Collections.Generic.List[object]]::new()
$functions=$ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$true)
foreach($name in @('Read-Ui','Find-Node','Find-SearchEditor','Find-ExactDocument','Search-Document','Tap-Node','Get-PickerBounds','Test-PickerContains','Test-PickerVisible','Get-OpenPickerRoots','Get-QAProviderRow','Open-Import')) {
  $definition=@($functions | Where-Object {$_.Name -eq $name})
  if ($definition.Count -ne 1) { throw "Expected one helper function: $name" }
  . ([scriptblock]::Create($definition[0].Extent.Text))
}
$prefixAst=$ast.FindAll({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$prefix'},$true)
if ($prefixAst.Count -ne 1) { throw 'Expected one helper remote prefix.' }
$remoteBase=$prefixAst[0].Right.FindAll({param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst]},$true)[0].Value
function Assert([bool]$Condition,[string]$Message) { if (!$Condition) { throw $Message } }
function Start-Sleep { param([int]$Milliseconds) }
function Artifact([string]$Name) { return Join-Path $script:output $Name }
function Adb([string[]]$Arguments,[switch]$AllowFailure) {
  $script:observed.Add($Arguments)
  $script:lastAdbExit=0
  if ($Arguments[0] -eq 'shell' -and $Arguments[1] -eq 'uiautomator') { return 'UI hierchary dumped to: '+$Arguments[3] }
  if ($Arguments[0] -eq 'pull') {
    if($script:navigationFrames) { $script:lastFrame=$script:navigationFrames[$script:navigationState] }
    elseif ($script:frames.Count) { $script:lastFrame=$script:frames.Dequeue() }
    $script:lastFrame | Set-Content -LiteralPath $Arguments[2] -Encoding utf8
  } elseif($Arguments[0] -eq 'shell' -and $Arguments[1] -eq 'input' -and $Arguments[2] -eq 'tap' -and $script:navigationFrames) {
    $point=$Arguments[3]+' '+$Arguments[4]
    if($script:navigationState -in @('downloads','documents') -and $point -eq '74 126') { $script:navigationState='roots' }
    elseif($script:navigationState -eq 'roots' -and $point -in @('300 230','368 1152')) {
      if(!$script:navigationStaysOpen) { $script:navigationState='documents' }
    }
    else { throw "Unexpected navigation tap: state=$script:navigationState point=$point" }
    $script:navigationTransitions.Add($script:navigationState)
  } elseif ($Arguments[0] -ne 'shell' -or $Arguments[1] -ne 'input') {
    throw 'Pure fixture attempted an unexpected command; no native adb is allowed.'
  }
  return @()
}
function Reset([string]$Name,[string[]]$Xml=@()) {
  $script:output=Join-Path $resultRoot $Name
  New-Item -ItemType Directory -Path $script:output | Out-Null
  $script:sequence=0
  $script:remoteFiles=[Collections.Generic.List[string]]::new()
  $script:observed=[Collections.Generic.List[object]]::new()
  $script:frames=[Collections.Generic.Queue[string]]::new()
  foreach($frame in $Xml) { $script:frames.Enqueue($frame) }
  $script:lastFrame='<hierarchy />'
  $script:prefix=$remoteBase+'0123456789abcdef0123456789abcdef'
  $script:navigationFrames=$null
  $script:navigationState=$null
  $script:navigationStaysOpen=$false
  $script:navigationTransitions=[Collections.Generic.List[string]]::new()
}
function Must-Throw([scriptblock]$Action,[string]$Pattern) {
  $errorText=$null
  try { & $Action | Out-Null } catch { $errorText=$_.Exception.Message }
  Assert ($errorText -and $errorText -match $Pattern) "Expected failure: $Pattern"
}
function Node([string]$Text,[string]$Class='android.widget.TextView',[string]$Id='android:id/title',[string]$Desc='',
  [string]$Enabled='true',[string]$Clickable='true',[string]$Visible='true',[string]$Bounds='[10,100][500,160]') {
  $escaped=[Security.SecurityElement]::Escape($Text)
  return '<node text="'+$escaped+'" class="'+$Class+'" resource-id="'+$Id+'" content-desc="'+$Desc+'" enabled="'+$Enabled+'" clickable="'+$Clickable+'" visible-to-user="'+$Visible+'" bounds="'+$Bounds+'" />'
}
function Editor-Case([string]$Name,[scriptblock]$Action) {
  try { & $Action; $passed.Add($Name) }
  catch { $failed.Add(@{name=$Name;error=$_.Exception.Message}) }
}
$basename='jianzhang-valid-0123456789abcdef0123456789abcdef.json'
$toolbar='<hierarchy>'+(Node '' 'android.widget.Button' 'com.android.documentsui:id/option_menu_search' 'Search')+'</hierarchy>'
$editor='<hierarchy>'+(Node 'old' 'android.widget.EditText' 'android:id/search_src_text')+'</hierarchy>'
$exact='<hierarchy>'+(Node $basename 'android.widget.EditText' 'android:id/search_src_text')+(Node $basename)+'</hierarchy>'

Reset 'tmp-prefix' @($toolbar)
Read-Ui 'tmp' | Out-Null
Assert ($remoteBase -eq '/data/local/tmp/jianzhang-saf-') 'QA artifact prefix must leave Downloads clean.'
Assert ($remoteFiles.Count -eq 1 -and $remoteFiles[0].StartsWith('/data/local/tmp/')) 'XML dump was not in shell tmp.'
$downloadConstants=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value.StartsWith('/sdcard/Download')},$true))
Assert ($downloadConstants.Count -eq 1 -and $downloadConstants[0].Value -eq '/sdcard/Download/') 'Only the intentional valid JSON may be placed in Downloads.'
$passed.Add('remote artifacts avoid Downloads; only intended valid JSON is visible')

Reset 'exact-search' @($toolbar,$editor,$exact)
$selected=Search-Document $basename
Assert ($selected.GetAttribute('resource-id') -eq 'android:id/title') 'Search input was mistaken for the file result.'
$typed=@($observed | Where-Object {$_[0] -eq 'shell' -and $_[1] -eq 'input' -and $_[2] -eq 'text'})
Assert ($typed.Count -eq 1 -and $typed[0][3] -ceq $basename) 'Search must type exactly the intended basename.'
$deletes=@($observed | Where-Object {$_[2] -eq 'keyevent' -and $_[3] -eq '67'})
Assert ($deletes.Count -eq 3) 'Previous search query was not cleared.'
Assert (@($observed | Where-Object {$_[2] -eq 'keyevent' -and $_[3] -eq '66'}).Count -eq 1) 'Search was not submitted.'
$passed.Add('system Search types exact basename; editor excluded; prior query cleared')

$wrong='<hierarchy>'+(Node $basename 'android.widget.EditText' 'android:id/search_src_text')+(Node ($basename+'.bak'))+'</hierarchy>'
Reset 'wrong-file' @($wrong)
Must-Throw { Find-ExactDocument $basename } 'not found'
Assert (@($observed | Where-Object {$_[1] -eq 'uiautomator'}).Count -eq 4) 'Wrong-file search must fail within bounded attempts.'
$passed.Add('matching query text and a suffix file cannot satisfy exact document search')

Reset 'timeout'
Must-Throw { Find-ExactDocument $basename } 'not found'
Assert (@($observed | Where-Object {$_[1] -eq 'uiautomator'}).Count -eq 4) 'Empty search must fail after four attempts.'
$passed.Add('empty search timeout remains a failure')

$duplicate='<hierarchy>'+(Node $basename)+(Node $basename)+'</hierarchy>'
Reset 'ambiguous' @($duplicate)
Must-Throw { Find-ExactDocument $basename } 'ambiguous'
$passed.Add('duplicate exact document titles fail rather than select arbitrarily')

Reset 'unsafe-query'
Must-Throw { Search-Document 'unexpected file.json' } 'Unexpected'
Assert ($observed.Count -eq 0) 'Unexpected basename must be rejected before any command.'
$passed.Add('unexpected basename rejected before keyboard commands')

# Execute the actual unchanged guard conditions against small local dummy
# files. This does not inspect or modify any release APK or real manifest.
Reset 'sha-guards'
$releaseApk=Join-Path $output 'release.apk'
$providerApk=Join-Path $output 'provider.apk'
$fixturePath=Join-Path $output 'fixture.json'
$releasePath=Join-Path $output 'release-manifest.json'
$sourcePath=Join-Path $output 'source-manifest.json'
$providerPath=Join-Path $output 'provider-manifest.json'
foreach($file in @($releaseApk,$providerApk,$fixturePath,$releasePath,$sourcePath,$providerPath)) { 'fixture' | Set-Content $file -Encoding utf8 }
function Sha([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
$release=@{sha256=(Sha $releaseApk)}
$provider=@{sha256=(Sha $providerApk);legacyLedgerFixtureSha256=(Sha $fixturePath)}
$releaseHash=Sha $releasePath
$sourceHash=Sha $sourcePath
$providerHash=Sha $providerPath
$ifs=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.IfStatementAst]},$true))
function Guard([string]$Message) {
  $found=@($ifs | Where-Object {$_.Extent.Text.Contains($Message)})
  Assert ($found.Count -eq 1) "Expected one real SHA guard: $Message"
  return [scriptblock]::Create($found[0].Extent.Text)
}
$begin=Guard 'Local delivery APK identity mismatch.'
$end=Guard 'Delivery APK or shared fixture changed during tests.'
$manifests=Guard 'Artifact manifests changed during tests.'
& $begin
& $end
& $manifests
'changed' | Set-Content $releaseApk
Must-Throw { & $begin } 'identity mismatch'
Must-Throw { & $end } 'changed'
'fixture' | Set-Content $releaseApk -Encoding utf8
'changed' | Set-Content $providerApk
Must-Throw { & $begin } 'identity mismatch'
'fixture' | Set-Content $providerApk -Encoding utf8
'changed' | Set-Content $fixturePath
Must-Throw { & $end } 'changed'
'fixture' | Set-Content $fixturePath -Encoding utf8
'changed' | Set-Content $sourcePath
Must-Throw { & $manifests } 'changed'
Assert (@($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Assert-FileContract'},$true)).Count -eq 4) 'Client and provider source contracts must remain guarded before and after.'
$passed.Add('real begin/end local APK, shared fixture, source-manifest drift guards fail')

$raw=Get-Content -LiteralPath $helper -Raw
Assert ($raw.Contains("Find-Node '确认恢复备份'") -and $raw.Contains('preview-count') -and $raw.Contains("Find-Node '^取消$'") -and $raw.Contains('Cancelled valid preview retained import cache.') -and $raw.Contains("Snapshot-Database 'valid-cancel-after'")) 'Valid preview, exact fixture count, cancellation, cache and SQL assertions must remain.'
$passed.Add('valid preview/count/cancel/cache/all-table SQL checks retained')

# This search node was captured from the actual API 35 DocumentsUI failure.
# Pure fixtures replay it; neither a device nor the original evidence is needed.
$api35Search='<node index="0" text="Search…" resource-id="com.android.documentsui:id/search_src_text" class="android.widget.AutoCompleteTextView" package="com.android.documentsui" content-desc="" checkable="false" checked="false" clickable="true" enabled="true" focusable="true" focused="true" scrollable="false" long-clickable="true" password="false" selected="false" bounds="[210,78][1059,173]" />'
Editor-Case 'actual API35 AutoCompleteTextView search editor is recognized' {
  Reset 'actual-api35-search' @('<hierarchy>'+$api35Search+'</hierarchy>')
  $selected=Find-SearchEditor
  Assert ($selected.GetAttribute('resource-id') -eq 'com.android.documentsui:id/search_src_text') 'Actual DocumentsUI editor was not selected.'
  Assert ($selected.GetAttribute('class') -eq 'android.widget.AutoCompleteTextView') 'Actual editor class changed.'
}
Editor-Case 'legacy EditText supports both standard search resource IDs' {
  foreach($id in @('android:id/search_src_text','com.android.documentsui:id/search_src_text')) {
    Reset ('legacy-'+$id.Split(':')[0]) @('<hierarchy>'+(Node 'old' 'android.widget.EditText' $id)+'</hierarchy>')
    $selected=Find-SearchEditor
    Assert ($selected.GetAttribute('resource-id') -eq $id) 'Legacy standard search editor was not selected.'
  }
}
Editor-Case 'editable field with unrelated resource ID is rejected' {
  Reset 'wrong-editor-id' @('<hierarchy>'+(Node 'old' 'android.widget.EditText' 'com.other:id/search_src_text')+'</hierarchy>')
  Must-Throw { Find-SearchEditor } 'missing'
}
Editor-Case 'same-name non-editor cannot satisfy search-editor selection' {
  Reset 'same-name-non-editor' @('<hierarchy>'+(Node $basename 'android.widget.TextView' 'com.android.documentsui:id/search_src_text')+'</hierarchy>')
  Must-Throw { Find-SearchEditor } 'missing'
}
Editor-Case 'query document title is not a search editor' {
  Reset 'query-title-editor' @('<hierarchy>'+(Node $basename 'android.widget.EditText' 'android:id/title')+'</hierarchy>')
  Must-Throw { Find-SearchEditor } 'missing'
}
Editor-Case 'duplicate standard search editors are rejected' {
  Reset 'duplicate-editors' @('<hierarchy>'+(Node 'old' 'android.widget.EditText' 'android:id/search_src_text')+$api35Search+'</hierarchy>')
  Must-Throw { Find-SearchEditor } 'ambiguous'
}
Editor-Case 'disabled standard search editor is rejected' {
  Reset 'disabled-editor' @('<hierarchy>'+(Node 'old' 'android.widget.EditText' 'android:id/search_src_text' '' 'false')+'</hierarchy>')
  Must-Throw { Find-SearchEditor } 'missing'
}
Editor-Case 'nonclickable standard search editor is rejected' {
  Reset 'nonclickable-editor' @('<hierarchy>'+(Node 'old' 'android.widget.EditText' 'android:id/search_src_text' '' 'true' 'false')+'</hierarchy>')
  Must-Throw { Find-SearchEditor } 'missing'
}
Editor-Case 'explicitly hidden standard search editor is rejected' {
  Reset 'hidden-editor' @('<hierarchy>'+(Node 'old' 'android.widget.EditText' 'android:id/search_src_text' '' 'true' 'true' 'false')+'</hierarchy>')
  Must-Throw { Find-SearchEditor } 'missing'
}
Editor-Case 'malformed, negative, empty and inverted editor bounds are rejected' {
  $badBounds=@('bad','[-1,100][500,160]','[10,100][10,160]','[10,100][500,100]','[500,100][10,160]','[10,160][500,100]')
  for($index=0;$index -lt $badBounds.Count;$index++) {
    Reset ('bad-editor-bounds-'+$index) @('<hierarchy>'+(Node 'old' 'android.widget.EditText' 'android:id/search_src_text' '' 'true' 'true' 'true' $badBounds[$index])+'</hierarchy>')
    Must-Throw { Find-SearchEditor } 'missing'
  }
}
Editor-Case 'both editable query classes are excluded from document title selection' {
  foreach($class in @('android.widget.EditText','android.widget.AutoCompleteTextView')) {
    Reset ('query-title-'+$class.Split('.')[-1]) @('<hierarchy>'+(Node $basename $class 'android:id/title')+(Node $basename)+'</hierarchy>')
    $selected=Find-ExactDocument $basename
    Assert ($selected.GetAttribute('class') -eq 'android.widget.TextView') 'Editable query title was mistaken for document.'
  }
}
Editor-Case 'actual API35 search types exact basename and selects a unique document' {
  $query='<hierarchy>'+(Node $basename 'android.widget.AutoCompleteTextView' 'com.android.documentsui:id/search_src_text')+(Node $basename)+'</hierarchy>'
  Reset 'actual-api35-search-flow' @($toolbar,('<hierarchy>'+$api35Search+'</hierarchy>'),$query)
  $selected=Search-Document $basename
  Assert ($selected.GetAttribute('resource-id') -eq 'android:id/title') 'Actual API35 query field was mistaken for document.'
  $typed=@($observed | Where-Object {$_[0] -eq 'shell' -and $_[1] -eq 'input' -and $_[2] -eq 'text'})
  Assert ($typed.Count -eq 1 -and $typed[0][3] -ceq $basename) 'Actual API35 search did not type exact unique basename.'
}

# These navigation fixtures expose subsequent pages only after the correct tap.
# A polling-only implementation cannot accidentally read an already-open drawer.
function Open-Picker { return Read-Ui 'navigation-picker' }
$faultDocument='可靠管道错误.json'
$faultProvider='简账 QA 故障文件'
$drawerNode='<node text="" resource-id="" class="android.widget.ImageButton" content-desc="Show roots" enabled="true" clickable="true" bounds="[0,63][147,189]" />'
$providerNode=Node $faultProvider 'android.widget.TextView' 'android:id/title' '' 'true' 'false' 'true' '[0,200][600,260]'
$documentNode=Node $faultDocument 'android.widget.TextView' 'android:id/title' '' 'true' 'false' 'true' '[0,300][600,360]'
$downloads='<hierarchy>'+(Node 'Downloads')+$drawerNode+'</hierarchy>'
function Roots-Frame([string]$Rows,[string]$DrawerExtra='', [string]$DrawerBounds='[0,63][735,1920]',[string]$ListBounds='[0,189][735,1794]',[string]$Header='') {
  return '<hierarchy><node resource-id="com.android.documentsui:id/drawer_roots" class="android.widget.LinearLayout" enabled="true" bounds="'+$DrawerBounds+'" '+$DrawerExtra+'>'+$Header+'<node resource-id="com.android.documentsui:id/roots_list" class="android.widget.ListView" enabled="true" bounds="'+$ListBounds+'">'+$Rows+'</node></node></hierarchy>'
}
function Provider-Row([string]$Title=$providerNode,[string]$Bounds='[0,200][600,260]',[string]$Extra='') {
  return '<node class="android.widget.LinearLayout" enabled="true" clickable="true" bounds="'+$Bounds+'" '+$Extra+'>'+$Title+'</node>'
}
$roots=Roots-Frame (Provider-Row)
$documents='<hierarchy>'+$drawerNode+$documentNode+'</hierarchy>'
function Navigation([string]$Name,[string]$State='downloads',[string]$DownloadsFrame=$downloads,[string]$RootsFrame=$roots,[string]$DocumentsFrame=$documents) {
  Reset $Name
  $script:navigationState=$State
  $script:navigationFrames=@{downloads=$DownloadsFrame;roots=$RootsFrame;documents=$DocumentsFrame}
}
function Navigation-Taps { return ,@($observed | Where-Object {$_[0] -eq 'shell' -and $_[1] -eq 'input' -and $_[2] -eq 'tap'}) }
Editor-Case 'actual Open-Import opens roots from Downloads before selecting the exact QA provider' {
  Navigation 'navigation-downloads'
  $selected=Open-Import $faultDocument
  Assert ($selected.GetAttribute('text') -ceq $faultDocument -and $selected.GetAttribute('resource-id') -eq 'android:id/title') 'Wrong fault document was selected.'
  Assert ((Navigation-Taps).Count -eq 2 -and ($navigationTransitions.ToArray() -join ',') -ceq 'roots,documents') 'Navigation must tap the roots drawer then QA provider; not the document itself.'
}
Editor-Case 'actual Open-Import skips opening drawer when QA provider is already visible' {
  Navigation 'navigation-provider-visible' 'roots'
  $selected=Open-Import $faultDocument
  Assert ($selected.GetAttribute('text') -ceq $faultDocument -and (Navigation-Taps).Count -eq 1 -and $navigationState -eq 'documents') 'Already-visible provider must require just one provider tap.'
}
Editor-Case 'actual Open-Import confirms QA provider even when exact document text is already present' {
  Navigation 'navigation-document-visible' 'documents'
  $selected=Open-Import $faultDocument
  Assert ($selected.GetAttribute('text') -ceq $faultDocument -and (Navigation-Taps).Count -eq 2 -and ($navigationTransitions.ToArray() -join ',') -ceq 'roots,documents') 'Already-present document title must not bypass exact provider confirmation.'
}
Editor-Case 'actual Open-Import recognizes Chinese roots drawer label' {
  Navigation 'navigation-chinese-drawer' 'downloads' ($downloads.Replace('Show roots','显示根目录'))
  $selected=Open-Import $faultDocument
  Assert ($selected.GetAttribute('text') -ceq $faultDocument -and (Navigation-Taps).Count -eq 2) 'Chinese roots drawer did not lead to exact QA document.'
}
Editor-Case 'actual Open-Import rejects missing roots drawer without navigating elsewhere' {
  Navigation 'navigation-missing-drawer' 'downloads' '<hierarchy />'
  Must-Throw { Open-Import $faultDocument } 'Missing UI'
  Assert ((Navigation-Taps).Count -eq 0) 'Missing drawer must not trigger a guessed tap.'
}
Editor-Case 'actual Open-Import rejects missing QA provider and suffix names after opening roots' {
  $other=Roots-Frame (Provider-Row (Node ($faultProvider+' 副本')))
  Navigation 'navigation-missing-provider' 'downloads' $downloads $other
  Must-Throw { Open-Import $faultDocument } 'not found'
  Assert ((Navigation-Taps).Count -eq 1 -and $navigationState -eq 'roots') 'Missing exact provider must stop after opening drawer.'
}
Editor-Case 'actual Open-Import rejects missing exact fault document without choosing any other file' {
  $other='<hierarchy>'+(Node ($faultDocument+'.bak'))+(Node '可靠管道错误Xjson')+'</hierarchy>'
  Navigation 'navigation-missing-document' 'roots' $downloads $roots $other
  Must-Throw { Open-Import $faultDocument } 'not found'
  Assert ((Navigation-Taps).Count -eq 1 -and $navigationState -eq 'documents') 'Missing document must stop at provider contents.'
}
Editor-Case 'actual Open-Import excludes same-name editable query fields' {
  $query='<hierarchy>'+$drawerNode+(Node $faultDocument 'android.widget.AutoCompleteTextView' 'com.android.documentsui:id/search_src_text')+'</hierarchy>'
  Navigation 'navigation-query-not-document' 'documents' $downloads $roots $query
  Must-Throw { Open-Import $faultDocument } 'Missing UI|not found'
  Assert ((Navigation-Taps).Count -eq 2) 'Only drawer/provider navigation may occur; query must not be selected as document.'
}
Editor-Case 'actual Open-Import rejects duplicate exact document titles' {
  Navigation 'navigation-duplicate-document' 'documents' $downloads $roots ('<hierarchy>'+$drawerNode+$documentNode+$documentNode+'</hierarchy>')
  Must-Throw { Open-Import $faultDocument } 'ambiguous'
  Assert ((Navigation-Taps).Count -eq 2) 'Duplicate document must not cause a file tap after drawer/provider confirmation.'
}
Editor-Case 'actual Open-Import rejects duplicate exact QA providers' {
  Navigation 'navigation-duplicate-provider' 'roots' $downloads (Roots-Frame ((Provider-Row)+(Provider-Row)))
  Must-Throw { Open-Import $faultDocument } 'ambiguous'
  Assert ((Navigation-Taps).Count -eq 0) 'Duplicate provider must not cause an arbitrary tap.'
}
Editor-Case 'actual Open-Import rejects duplicate roots drawer controls' {
  Navigation 'navigation-duplicate-drawer' 'downloads' ('<hierarchy>'+$drawerNode+$drawerNode+'</hierarchy>')
  Must-Throw { Open-Import $faultDocument } 'ambiguous'
  Assert ((Navigation-Taps).Count -eq 0) 'Duplicate drawer must not cause an arbitrary tap.'
}

# Complete original API35 007 hierarchy; compressed only to keep fixture code readable.
# Decoded bytes must retain original SHA256 e1613242dba8b6f35ff2548bcb24133b04b637f5a4b8de64bb1bcce5bbd6db7e.
$overlayCompressed=[IO.MemoryStream]::new([Convert]::FromBase64String('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'))
$overlayGzip=[IO.Compression.GZipStream]::new($overlayCompressed,[IO.Compression.CompressionMode]::Decompress)
$overlayBuffer=[IO.MemoryStream]::new()
try {
  $overlayGzip.CopyTo($overlayBuffer)
  $overlayBytes=$overlayBuffer.ToArray()
  $digest=[Security.Cryptography.SHA256]::HashData($overlayBytes)
  Assert ([Convert]::ToHexString($digest).ToLowerInvariant() -ceq 'e1613242dba8b6f35ff2548bcb24133b04b637f5a4b8de64bb1bcce5bbd6db7e') 'Actual 007 hierarchy bytes changed.'
  $api35DrawerOverlay=[Text.Encoding]::UTF8.GetString($overlayBytes).TrimStart([char]0xfeff)
} finally { $overlayBuffer.Dispose();$overlayGzip.Dispose();$overlayCompressed.Dispose() }
Editor-Case 'actual complete API35 drawer overlay cannot select its backing provider document' {
  Navigation 'actual-api35-drawer-overlay' 'roots' $downloads $api35DrawerOverlay $documents
  $selected=Open-Import $faultDocument
  Assert ($navigationState -eq 'documents' -and (Navigation-Taps).Count -eq 1 -and $selected.GetAttribute('bounds') -ceq '[0,300][600,360]') 'Actual 007 overlay must first select the real QA root inside the drawer.'
  $tap=(Navigation-Taps)[0]
  Assert ($tap[3] -eq '368' -and $tap[4] -eq '1152') 'Actual drawer root must tap its clickable parent row, not backing document/scrim.'
}
Editor-Case 'closed, hidden and zero-area drawer/list cannot be treated as open' {
  $bad=@(
    (Roots-Frame (Provider-Row) '' '[0,63][0,1920]'),
    (Roots-Frame (Provider-Row) 'visible-to-user="false"'),
    (Roots-Frame (Provider-Row) '' '[0,63][735,1920]' '[0,189][0,1794]'),
    (Roots-Frame (Provider-Row) '' '[-735,63][0,1920]')
  )
  for($index=0;$index -lt $bad.Count;$index++) {
    [xml]$hierarchy=$bad[$index]
    Assert ($null -eq (Get-OpenPickerRoots @($hierarchy.SelectNodes('//node')))) 'Invalid or hidden drawer was considered open.'
    $closed='<hierarchy>'+$drawerNode+$bad[$index].Replace('<hierarchy>','').Replace('</hierarchy>','')+'</hierarchy>'
    Navigation ('navigation-closed-drawer-'+$index) 'downloads' $closed
    $selected=Open-Import $faultDocument
    Assert ($selected.GetAttribute('text') -ceq $faultDocument -and (Navigation-Taps).Count -eq 2) 'Closed drawer must be explicitly opened before choosing provider.'
  }
}
Editor-Case 'same-name toolbar and drawer header outside roots_list are ignored' {
  $header=Node $faultProvider 'android.widget.TextView' 'android:id/title' '' 'true' 'false' 'true' '[0,90][600,150]'
  $frame=Roots-Frame (Provider-Row) '' '[0,63][735,1920]' '[0,189][735,1794]' $header
  $outside=Node $faultProvider 'android.widget.TextView' 'com.android.documentsui:id/breadcrumb_text' '' 'true' 'false' 'true' '[800,200][1000,260]'
  $frame=$frame.Replace('</hierarchy>',$outside+'</hierarchy>')
  Navigation 'navigation-header-breadcrumb' 'roots' $downloads $frame
  $selected=Open-Import $faultDocument
  Assert ((Navigation-Taps).Count -eq 1 -and $selected.GetAttribute('text') -ceq $faultDocument) 'Header or breadcrumb polluted exact provider matching.'
}
Editor-Case 'roots_list without legitimate drawer ancestry cannot select a provider' {
  $orphan='<hierarchy><node resource-id="com.android.documentsui:id/roots_list" enabled="true" bounds="[0,189][735,1794]">'+(Provider-Row)+'</node></hierarchy>'
  Navigation 'navigation-orphan-roots-list' 'roots' $downloads $orphan
  Must-Throw { Open-Import $faultDocument } 'Missing UI'
  Assert ((Navigation-Taps).Count -eq 0) 'Orphan roots_list must not permit provider tap.'
}
Editor-Case 'same-name header inside drawer but outside roots_list cannot satisfy missing provider' {
  $header=Node $faultProvider 'android.widget.TextView' 'android:id/title' '' 'true' 'false' 'true' '[0,90][600,150]'
  $frame=Roots-Frame '' '' '[0,63][735,1920]' '[0,189][735,1794]' $header
  Navigation 'navigation-header-not-root' 'roots' $downloads $frame
  Must-Throw { Open-Import $faultDocument } 'not found'
  Assert ((Navigation-Taps).Count -eq 0) 'Drawer header must never be tapped as QA provider.'
}
Editor-Case 'provider title and clickable row must lie in valid drawer/list area' {
  $outside=Node $faultProvider 'android.widget.TextView' 'android:id/title' '' 'true' 'false' 'true' '[800,200][1000,260]'
  $bad=@(
    (Roots-Frame (Provider-Row $outside '[700,200][1080,300]')),
    (Roots-Frame (Provider-Row $providerNode '[0,100][600,260]'))
  )
  for($index=0;$index -lt $bad.Count;$index++) {
    Navigation ('navigation-outside-root-area-'+$index) 'roots' $downloads $bad[$index]
    Must-Throw { Open-Import $faultDocument } 'not found'
    Assert ((Navigation-Taps).Count -eq 0) 'Out-of-area title or parent row caused a scrim/header tap.'
  }
}
Editor-Case 'nonclickable title is valid only with a visible enabled clickable parent row' {
  $bad=@(
    (Roots-Frame ((Provider-Row).Replace('clickable="true"','clickable="false"'))),
    (Roots-Frame ((Provider-Row).Replace('<node class="android.widget.LinearLayout" enabled="true"','<node class="android.widget.LinearLayout" enabled="false"')))
  )
  for($index=0;$index -lt $bad.Count;$index++) {
    Navigation ('navigation-invalid-root-parent-'+$index) 'roots' $downloads $bad[$index]
    Must-Throw { Open-Import $faultDocument } 'not found'
    Assert ((Navigation-Taps).Count -eq 0) 'Invalid root parent must not be clicked.'
  }
}
Editor-Case 'duplicate actually open roots panels are rejected' {
  $panel=$roots.Replace('<hierarchy>','').Replace('</hierarchy>','')
  Navigation 'navigation-duplicate-panels' 'roots' $downloads ('<hierarchy>'+$panel+$panel+'</hierarchy>')
  Must-Throw { Open-Import $faultDocument } 'ambiguous'
  Assert ((Navigation-Taps).Count -eq 0) 'Duplicate open panels must not cause any selection.'
}
Editor-Case 'provider row selection cannot return backing document until drawer closes' {
  Navigation 'navigation-drawer-stays-open' 'roots' $downloads $api35DrawerOverlay $documents
  $script:navigationStaysOpen=$true
  Must-Throw { Open-Import $faultDocument } 'obscured'
  Assert ((Navigation-Taps).Count -eq 1 -and $navigationState -eq 'roots') 'Unclosed overlay must stop without document/scrim tap.'
}
Editor-Case 'hidden document ancestor prevents final document selection' {
  $hidden='<hierarchy>'+ $drawerNode +'<node enabled="true" visible-to-user="false" bounds="[0,200][1080,1900]">'+$documentNode+'</node></hierarchy>'
  Navigation 'navigation-hidden-document-parent' 'roots' $downloads $roots $hidden
  Must-Throw { Open-Import $faultDocument } 'not visible'
  Assert ((Navigation-Taps).Count -eq 1) 'Hidden document ancestry must prevent file tap.'
}

# Run the actual Adb body under a distinct name. Its command is a pure PS
# function that emits an ErrorRecord; no adb binary or emulator is invoked.
$realAdb=@($functions | Where-Object {$_.Name -eq 'Adb'})
Assert ($realAdb.Count -eq 1) 'Expected one actual ADB output collector.'
. ([scriptblock]::Create($realAdb[0].Extent.Text.Replace('function Adb(', 'function Invoke-ActualAdbFixture(')))
function Invoke-FakeNativeAdb {
  param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Received)
  $script:fakeNativeArguments=$Received
  Write-Output '标准输出：账单 6 笔 💚'
  Write-Error -Message '标准错误：故障管道 💚' -ErrorAction Continue
  $global:LASTEXITCODE=$script:fakeNativeExit
}
$adb='Invoke-FakeNativeAdb'
$Serial='pure-fixture-no-native-device'
Editor-Case 'actual Adb collector preserves Unicode stdout/stderr as strings and depth5 JSON without warnings' {
  $script:fakeNativeExit=0
  $commands=[Collections.Generic.List[object]]::new()
  $result=@(Invoke-ActualAdbFixture @('shell','qa-read-only'))
  Assert ($result.Count -eq 2 -and @($result | Where-Object {$_ -isnot [string]}).Count -eq 0) 'Captured stdout and ErrorRecord stderr must both be strings.'
  Assert ($result[0] -ceq '标准输出：账单 6 笔 💚' -and $result[1] -ceq '标准错误：故障管道 💚') 'Unicode stdout/stderr text changed.'
  $warnings=@()
  $json=ConvertTo-Json -InputObject $commands.ToArray() -Depth 5 -WarningVariable warnings
  Assert ($warnings.Count -eq 0) 'Actual command evidence JSON must not truncate nested ErrorRecord objects.'
  $parsed=$json | ConvertFrom-Json
  Assert ($parsed.output[0] -ceq $result[0] -and $parsed.output[1] -ceq $result[1] -and $parsed.exitCode -eq 0 -and $parsed.at -and $parsed.finishedAt) 'Command evidence lost complete lines, exit code or timestamps.'
  Assert (($parsed.arguments -join ',') -ceq '-s,pure-fixture-no-native-device,shell,qa-read-only') 'Recorded exact command arguments changed.'
}
Editor-Case 'actual Adb collector records nonzero exit for allowed failure and throws for disallowed failure' {
  $script:fakeNativeExit=17
  $commands=[Collections.Generic.List[object]]::new()
  $result=@(Invoke-ActualAdbFixture @('shell','qa-fail') -AllowFailure)
  Assert ($script:lastAdbExit -eq 17 -and $commands.Count -eq 1 -and $commands[0].exitCode -eq 17 -and $result.Count -eq 2) 'AllowFailure must preserve the real failure exit and output.'
  Assert (@($commands[0].output | Where-Object {$_ -isnot [string]}).Count -eq 0) 'Allowed failure command evidence must still contain only strings.'
  Must-Throw { Invoke-ActualAdbFixture @('shell','qa-fail') } 'ADB failed: shell qa-fail:.*标准错误：故障管道'
  Assert ($commands.Count -eq 2 -and $commands[1].exitCode -eq 17 -and $commands[1].output[1] -ceq '标准错误：故障管道 💚') 'Disallowed failure must be recorded before it is thrown.'
}

@{status=$(if($failed.Count){'failed'}else{'passed'});helperSha256=(Sha $helper);cases=$passed.ToArray();count=$passed.Count;failures=$failed.ToArray();failedCount=$failed.Count;nativeAdbUsed=$false;fixtureOutput=$resultRoot;completedAt=[DateTimeOffset]::UtcNow.ToString('o')} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $resultRoot 'result.json') -Encoding utf8
if($failed.Count) { throw "SAF pure fixtures failed: $($failed.Count); evidence $resultRoot" }
Write-Output "SAF pure fixtures passed: $($passed.Count); evidence $resultRoot"
