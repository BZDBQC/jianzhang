Unicode true
!include "MUI2.nsh"
!include "WinVer.nsh"
!include "x64.nsh"
!include "LogicLib.nsh"
!include "FileFunc.nsh"
!ifndef BUNDLE_DIR
  !error "BUNDLE_DIR must contain the complete Flutter release bundle."
!endif
!ifndef OUTPUT_FILE
  !error "OUTPUT_FILE must be supplied."
!endif
!ifndef APP_ICON
  !error "APP_ICON must be supplied."
!endif
!ifndef TX_HELPER
  !error "TX_HELPER must contain the compiled installer transaction helper."
!endif
!ifndef TX_CONFIG
  !error "TX_CONFIG must contain the verified complete payload contract."
!endif
!ifndef TX_CONFIG_SHA256
  !error "TX_CONFIG_SHA256 must identify the embedded payload contract."
!endif
!ifndef BUNDLE_CHECKS
  !error "BUNDLE_CHECKS must be supplied."
!endif
!ifndef BUNDLE_DELETE
  !error "BUNDLE_DELETE must be supplied."
!endif

!ifndef APP_VERSION
  !define APP_VERSION "2.0.0"
!endif
!ifdef QA_OUTPUT
  ; Redirect test integration to fixtures, never the user's installed app.
  !ifndef QA_ROOT
    !error "QA_ROOT must be supplied with QA_OUTPUT."
  !endif
  !define DEFAULT_DIR "${QA_ROOT}\default"
  !define REG_KEY "Software\Jianzhang\NativeInstallerQA"
  !define MENU_DIR "$INSTDIR\_qa\menu"
  !define DESKTOP_DIR "$INSTDIR\_qa\desktop"
  OutFile "${QA_OUTPUT}"
!else
  !define DEFAULT_DIR "$LOCALAPPDATA\Programs\Jianzhang"
  !define REG_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\Jianzhang"
  !define MENU_DIR "$SMPROGRAMS\简账"
  !define DESKTOP_DIR "$DESKTOP"
  OutFile "${OUTPUT_FILE}"
!endif
Name "简账"
InstallDir "${DEFAULT_DIR}"
InstallDirRegKey HKCU "${REG_KEY}" "InstallLocation"
RequestExecutionLevel user
SetCompressor /SOLID lzma
ShowInstDetails show
Icon "${APP_ICON}"
UninstallIcon "${APP_ICON}"
VIProductVersion "${APP_VERSION}.0"
VIAddVersionKey /LANG=2052 "ProductName" "简账"
VIAddVersionKey /LANG=2052 "FileDescription" "简账安装程序"
VIAddVersionKey /LANG=2052 "FileVersion" "${APP_VERSION}"
VIAddVersionKey /LANG=2052 "LegalCopyright" "Copyright 2026 简账"
Var DestinationIssue
Var RecommendedDir
Var RegistrationRemoved
Var RegisteredVersion
Var TransactionCommand
Var TransactionResult
Var TransactionPrepared
Var OwnerPid
Var QaFailure
Var QaCrash
Var InstallerMutex
Var TransactionLine
!define MUI_ABORTWARNING
!define MUI_CUSTOMFUNCTION_ABORT OnUserAbort
!define MUI_ICON "${APP_ICON}"
!define MUI_UNICON "${APP_ICON}"
!define MUI_WELCOMEPAGE_TEXT "将安装简账 ${APP_VERSION}。无需账号即可记账，账单默认保存到此设备。$\r$\n$\r$\n推荐使用默认目录，无需管理员权限。写入失败不会登记为成功。"
!insertmacro MUI_PAGE_WELCOME
!define MUI_PAGE_CUSTOMFUNCTION_LEAVE VerifyDestination
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!define MUI_FINISHPAGE_RUN "$INSTDIR\Jianzhang.exe"
!define MUI_FINISHPAGE_RUN_TEXT "打开简账"
!define MUI_FINISHPAGE_TEXT "安装完成。首次打开即可离线记账，无需账号。云端保存需要手机号登录并联网。$\r$\n$\r$\n升级和卸载保留本机账本；请定期将 JSON 备份导出到应用外保存。"
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "SimpChinese"

!macro NormalizePath variable
  ; Unlike the NSIS instruction, this Win32 API also resolves nonexistent folders.
  System::Call 'kernel32::GetFullPathNameW(w "${variable}", i ${NSIS_MAX_STRLEN}, w .r9, p 0) i .r8'
  ${If} $8 == 0
  ${OrIf} $8 >= ${NSIS_MAX_STRLEN}
    StrCpy ${variable} ""
  ${Else}
    StrCpy $8 "$9" 1 -1
    ${If} $8 == "\"
      StrLen $8 "$9"
      ${If} $8 > 3
        StrCpy $9 "$9" -1
      ${EndIf}
    ${EndIf}
    StrCpy ${variable} "$9"
  ${EndIf}
!macroend

!macro CheckExistingFile filename
  ${If} ${FileExists} "$INSTDIR\${filename}"
    ClearErrors
    ; Append access tests permission without truncating or changing the file.
    FileOpen $0 "$INSTDIR\${filename}" a
    ${If} ${Errors}
      StrCpy $DestinationIssue "无法写入 $INSTDIR\${filename}。文件可能被占用、设为只读或受到权限限制。"
      Return
    ${EndIf}
    FileClose $0
  ${EndIf}
!macroend

Function CheckDestination
  !insertmacro NormalizePath $INSTDIR
  StrCpy $DestinationIssue ""
  ${If} $INSTDIR == ""
    StrCpy $DestinationIssue "安装路径无效或过长，请选择默认目录。"
    Return
  ${EndIf}
  !ifdef QA_OUTPUT
    StrLen $2 "${QA_ROOT}\"
    StrCpy $3 "$INSTDIR" $2
    ${If} $3 != "${QA_ROOT}\"
      StrCpy $DestinationIssue "QA installer destination must stay inside its test root."
      Return
    ${EndIf}
  !endif
  StrCpy $TransactionCommand "preflight"
  Call RunTransaction
FunctionEnd

!macro TransactionRunner functionName
Function ${functionName}
  ; Windows locks a process's current directory. Leave the staged payload
  ; before commit, rollback or cleanup tries to move or remove that tree.
  ClearErrors
  SetOutPath "$PLUGINSDIR"
  ${If} ${Errors}
    StrCpy $TransactionResult "2"
    StrCpy $DestinationIssue "无法进入安装事务临时目录，请检查临时目录权限。"
    Return
  ${EndIf}
  ClearErrors
  Delete "$PLUGINSDIR\transaction-result.txt"
  ClearErrors
  ExecWait '"$PLUGINSDIR\installer-transaction.exe" "$TransactionCommand" "$INSTDIR" "$PLUGINSDIR\transaction.json" "$OwnerPid" "$QaFailure" "$QaCrash" "$PLUGINSDIR\transaction-result.txt" "${TX_CONFIG_SHA256}"' $TransactionResult
  ${If} ${Errors}
    StrCpy $TransactionResult "2"
    StrCpy $DestinationIssue "无法启动安装事务工具，请检查 Windows .NET Framework 和临时目录权限。"
    Return
  ${EndIf}
  ${If} $TransactionResult != "0"
    StrCpy $DestinationIssue "安装事务失败，未报告成功。恢复标记将保留供重试。"
    ${If} ${FileExists} "$PLUGINSDIR\transaction-result.txt"
      FileOpen $4 "$PLUGINSDIR\transaction-result.txt" r
      FileSeek $4 2 SET
      StrCpy $DestinationIssue ""
      ${Do}
        ClearErrors
        FileReadUTF16LE $4 $TransactionLine
        ${If} ${Errors}
          ${ExitDo}
        ${EndIf}
        StrCpy $DestinationIssue "$DestinationIssue$TransactionLine"
      ${Loop}
      FileClose $4
    ${EndIf}
  ${Else}
    StrCpy $DestinationIssue ""
  ${EndIf}
FunctionEnd
!macroend
!insertmacro TransactionRunner RunTransaction
!insertmacro TransactionRunner un.RunTransaction

Function VerifyDestination
  Call CheckDestination
  ${If} $DestinationIssue != ""
    MessageBox MB_YESNO|MB_ICONEXCLAMATION "$DestinationIssue$\r$\n$\r$\n请关闭正在运行的简账启动器后重试。是否改用推荐目录？$\r$\n$RecommendedDir" IDNO choose_again
    StrCpy $INSTDIR "$RecommendedDir"
    Call CheckDestination
    ${If} $DestinationIssue == ""
      Return
    ${EndIf}
    MessageBox MB_OK|MB_ICONSTOP "$DestinationIssue$\r$\n请返回选择其他可写目录，或关闭占用程序后重试。"
    choose_again:
    Abort
  ${EndIf}
FunctionEnd

Function .onInit
  InitPluginsDir
  SetOutPath "$PLUGINSDIR"
  File /oname=installer-transaction.exe "${TX_HELPER}"
  File /oname=transaction.json "${TX_CONFIG}"
  System::Call 'kernel32::GetCurrentProcessId() i .r0'
  StrCpy $OwnerPid $0
  StrCpy $QaFailure "0"
  StrCpy $QaCrash "0"
  StrCpy $TransactionPrepared "0"
  !ifdef QA_OUTPUT
    ${GetOptions} $CMDLINE "/QAFAIL=" $QaFailure
    IfErrors 0 +2
      StrCpy $QaFailure "0"
    ${GetOptions} $CMDLINE "/QACRASH=" $QaCrash
    IfErrors 0 +2
      StrCpy $QaCrash "0"
    System::Call 'kernel32::CreateMutexW(p 0,i 0,w "Local\JianzhangNativeInstallerQA") p .r0 ?e'
  !else
    System::Call 'kernel32::CreateMutexW(p 0,i 0,w "Local\JianzhangNativeInstaller") p .r0 ?e'
  !endif
  Pop $1
  StrCpy $InstallerMutex $0
  ${If} $InstallerMutex == "0"
  ${OrIf} $1 == "183"
    SetErrorLevel 2
    Quit
  ${EndIf}
  !ifdef QA_OUTPUT
    StrCpy $0 "$INSTDIR"
    StrCpy $INSTDIR "${QA_ROOT}"
    LogSet on
    StrCpy $INSTDIR "$0"
  !endif
  StrCpy $RecommendedDir "${DEFAULT_DIR}"
  ReadRegStr $0 HKCU "${REG_KEY}" "InstallLocation"
  ${If} $0 != ""
    ${If} ${FileExists} "$0\Jianzhang.exe"
    ${OrIf} ${FileExists} "$0\Uninstall.exe"
      StrCpy $RecommendedDir "$0"
    ${EndIf}
  ${EndIf}
  ${IfNot} ${AtLeastWin10}
    IfSilent +2
      MessageBox MB_OK|MB_ICONSTOP "简账需要 Windows 10 或更高版本。"
    SetErrorLevel 2
    Quit
  ${EndIf}
  ${IfNot} ${IsNativeAMD64}
    IfSilent +2
      MessageBox MB_OK|MB_ICONSTOP "此安装包适用于 Windows 10/11 的 x64 电脑。"
    SetErrorLevel 2
    Quit
  ${EndIf}
  ; NSIS may replace an invalid /D with its default before .onInit.
  ; Validate the original request so silent installs cannot use another folder.
  ClearErrors
  ; $CMDLINE omits /D, so get the original Windows command line.
  System::Call 'kernel32::GetCommandLineW() w .r0'
  StrCpy $R0 "$0"
  ${GetOptions} $R0 "/D=" $R1
  ${IfNot} ${Errors}
    StrCpy $INSTDIR "$R1"
    Call CheckDestination
    ${If} $DestinationIssue != ""
      IfSilent +2
        MessageBox MB_OK|MB_ICONSTOP "$DestinationIssue"
      SetErrorLevel 2
      Quit
    ${EndIf}
  ${EndIf}
FunctionEnd

Section "简账" SEC_MAIN
  SetShellVarContext current
  Call CheckDestination
  ${If} $DestinationIssue != ""
    Goto destination_failed
  ${EndIf}
  StrCpy $TransactionCommand "prepare"
  Call RunTransaction
  ${If} $TransactionResult != "0"
    Goto destination_failed
  ${EndIf}
  StrCpy $TransactionPrepared "1"
  ; Candidate extraction is isolated from the old installation on the same
  ; volume. The helper verifies every staged hash before a directory commit.
  SetOverwrite on
  ClearErrors
  SetOutPath "$INSTDIR.__jianzhang_transaction\stage"
  File /r "${BUNDLE_DIR}\*"
  IfErrors file_failed
  WriteUninstaller "$INSTDIR.__jianzhang_transaction\stage\Uninstall.exe"
  IfErrors file_failed
  StrCpy $TransactionCommand "commit"
  Call RunTransaction
  StrCpy $TransactionPrepared "0"
  !ifdef QA_OUTPUT
    ${If} $TransactionResult == "99"
      SetErrorLevel 99
      Quit
    ${EndIf}
  !endif
  ${If} $TransactionResult != "0"
    Goto destination_failed
  ${EndIf}
  DetailPrint "简账 ${APP_VERSION} 安装成功。"
  SetErrorLevel 0
  Goto install_done
  file_failed:
    StrCpy $DestinationIssue "无法写入程序文件。已有文件或目录可能受到占用、权限或安全软件限制。"
    StrCpy $5 $DestinationIssue
    StrCpy $TransactionCommand "rollback"
    Call RunTransaction
    ${If} $TransactionResult == "0"
      StrCpy $DestinationIssue "$5$\r$\n旧安装状态已恢复。"
    ${EndIf}
    StrCpy $TransactionPrepared "0"
  destination_failed:
    !ifdef QA_OUTPUT
      FileOpen $4 "${QA_ROOT}\failure.txt" w
      FileWrite $4 "$DestinationIssue$\r$\nDestination=$INSTDIR$\r$\nOutput=$OUTDIR"
      FileClose $4
    !endif
    DetailPrint "$DestinationIssue"
    IfSilent +2
      MessageBox MB_OK|MB_ICONSTOP "$DestinationIssue$\r$\n$\r$\n安装未完成，请关闭占用程序后重试，或选择默认目录。"
    SetErrorLevel 2
    Abort "安装未完成"
  install_done:
SectionEnd

Function OnUserAbort
  ${If} $TransactionPrepared == "1"
    StrCpy $TransactionCommand "rollback"
    Call RunTransaction
    SetErrorLevel 2
  ${EndIf}
FunctionEnd

Function un.onInit
  ; Installation and uninstallation share one whole-operation mutex.
  !ifdef QA_OUTPUT
    System::Call 'kernel32::CreateMutexW(p 0,i 0,w "Local\JianzhangNativeInstallerQA") p .r0 ?e'
  !else
    System::Call 'kernel32::CreateMutexW(p 0,i 0,w "Local\JianzhangNativeInstaller") p .r0 ?e'
  !endif
  Pop $1
  StrCpy $InstallerMutex $0
  ${If} $InstallerMutex == "0"
  ${OrIf} $1 == "183"
    SetErrorLevel 2
    Quit
  ${EndIf}
  InitPluginsDir
  SetOutPath "$PLUGINSDIR"
  File /oname=installer-transaction.exe "${TX_HELPER}"
  File /oname=transaction.json "${TX_CONFIG}"
  System::Call 'kernel32::GetCurrentProcessId() i .r0'
  StrCpy $OwnerPid $0
  StrCpy $QaFailure "0"
  StrCpy $QaCrash "0"
FunctionEnd

Function un.CheckFiles
  !insertmacro NormalizePath $INSTDIR
  StrCpy $DestinationIssue ""
  ${If} $INSTDIR == ""
    StrCpy $DestinationIssue "卸载路径无效，请重新安装新版后再卸载。"
    Return
  ${EndIf}
  !ifdef QA_OUTPUT
    StrLen $2 "${QA_ROOT}\"
    StrCpy $3 "$INSTDIR" $2
    ${If} $3 != "${QA_ROOT}\"
      StrCpy $DestinationIssue "QA uninstaller destination must stay inside its test root."
      Return
    ${EndIf}
  !endif
  StrCpy $TransactionCommand "uninstall-preflight"
  Call un.RunTransaction
  ${If} $TransactionResult != "0"
    Return
  ${EndIf}
  !include "${BUNDLE_CHECKS}"
  !insertmacro CheckExistingFile "README.txt"
  !insertmacro CheckExistingFile "Uninstall.exe"
FunctionEnd

Section "Uninstall"
  SetShellVarContext current
  StrCpy $RegistrationRemoved "0"
  Call un.CheckFiles
  ${If} $DestinationIssue != ""
    Goto uninstall_failed
  ${EndIf}
  ${If} ${FileExists} "$INSTDIR.__jianzhang_transaction\journal.json"
    StrCpy $TransactionCommand "cleanup"
    Call un.RunTransaction
    ${If} $TransactionResult != "0"
      Goto uninstall_failed
    ${EndIf}
  ${EndIf}
  StrCpy $TransactionCommand "uninstall-begin"
  Call un.RunTransaction
  ${If} $TransactionResult != "0"
    Goto uninstall_failed
  ${EndIf}
  StrCpy $TransactionCommand "uninstall-delete-payload"
  Call un.RunTransaction
  ${If} $TransactionResult != "0"
    Goto uninstall_failed
  ${EndIf}
  ClearErrors
  !include "${BUNDLE_DELETE}"
  IfErrors uninstall_failed
  ; A previous directory must not remove a newer installation's global entries.
  ReadRegStr $0 HKCU "${REG_KEY}" "InstallLocation"
  StrCpy $1 "$INSTDIR"
  StrCmp $0 "" keep_new_install
  !insertmacro NormalizePath $0
  StrCmp $0 $1 0 keep_new_install
  ReadRegStr $RegisteredVersion HKCU "${REG_KEY}" "DisplayVersion"
  ClearErrors
  Delete "${DESKTOP_DIR}\简账.lnk"
  Delete "${MENU_DIR}\简账.lnk"
  Delete "${MENU_DIR}\卸载简账.lnk"
  IfErrors uninstall_failed
  RMDir "${MENU_DIR}"
  ; A nonempty shortcut folder is safe to keep and must not poison registry deletion.
  ClearErrors
  DeleteRegKey HKCU "${REG_KEY}"
  IfErrors uninstall_failed
  StrCpy $RegistrationRemoved "1"
  keep_new_install:
  StrCpy $TransactionCommand "uninstall-finish"
  Call un.RunTransaction
  ${If} $TransactionResult != "0"
    Goto restore_registration
  ${EndIf}
  RMDir "$INSTDIR"
  SetErrorLevel 0
  Goto uninstall_done
  restore_registration:
    ; Keep a usable retry entry if the final uninstaller file cannot be deleted.
    ${If} $RegistrationRemoved == "1"
      ClearErrors
      WriteRegStr HKCU "${REG_KEY}" "DisplayName" "简账"
      WriteRegStr HKCU "${REG_KEY}" "DisplayVersion" "$RegisteredVersion"
      WriteRegStr HKCU "${REG_KEY}" "InstallLocation" "$INSTDIR"
      WriteRegStr HKCU "${REG_KEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
      WriteRegDWORD HKCU "${REG_KEY}" "NoModify" 1
      WriteRegDWORD HKCU "${REG_KEY}" "NoRepair" 1
      ${If} ${Errors}
        StrCpy $DestinationIssue "卸载未完成，且无法恢复卸载信息。请重新安装新版后再卸载。"
      ${EndIf}
    ${EndIf}
  uninstall_failed:
    ${If} $DestinationIssue == ""
      StrCpy $DestinationIssue "无法删除简账文件或安装入口。请关闭占用程序后重试；卸载器及登记信息保留，不会报告成功。"
    ${EndIf}
    !ifdef QA_OUTPUT
      FileOpen $4 "${QA_ROOT}\failure.txt" w
      FileWrite $4 "$DestinationIssue$\r$\nDestination=$INSTDIR"
      FileClose $4
    !endif
    DetailPrint "$DestinationIssue"
    IfSilent +2
      MessageBox MB_OK|MB_ICONSTOP "$DestinationIssue"
    SetErrorLevel 2
    Abort "卸载未完成"
  uninstall_done:
SectionEnd
