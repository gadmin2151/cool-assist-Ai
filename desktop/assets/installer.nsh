; CPU inference requires Microsoft's signed Visual C++ x64 runtime.
; Bundled from the pinned official download; Windows displays its normal UAC prompt.
!include "StdUtils.nsh"
!include "WordFunc.nsh"
!macro CheckCoolAssistRuntime
  ReadRegDWORD $R0 HKLM "SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64" "Installed"
  ${If} $R0 == 1
    ReadRegStr $R3 HKLM "SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64" "Version"
    StrCpy $R4 $R3 1
    ${If} $R4 == "v"
      StrCpy $R3 $R3 "" 1
    ${EndIf}
    ${VersionCompare} $R3 "14.44.35211.0" $R4
    ${If} $R4 == 2
      StrCpy $R0 0
    ${EndIf}
  ${EndIf}
!macroend
!macro customInstall
  SetRegView 64
  !insertmacro CheckCoolAssistRuntime
  ${If} $R0 != 1
    InitPluginsDir
    SetOutPath "$PLUGINSDIR"
    File /oname=vc_redist.x64.exe "${BUILD_RESOURCES_DIR}/../runtime/vc_redist.x64.exe"
    DetailPrint "Installing Microsoft Visual C++ Runtime for local AI..."
    ${StdUtils.ExecShellWaitEx} $R1 $R2 "$PLUGINSDIR\vc_redist.x64.exe" "runas" "/install /passive /norestart"
    ${If} $R1 == "ok"
      ${StdUtils.WaitForProcEx} $R1 $R2
    ${EndIf}
    !insertmacro CheckCoolAssistRuntime
    ${If} $R0 != 1
      MessageBox MB_OK|MB_ICONEXCLAMATION "Local AI requires Microsoft Visual C++ 2015-2022 x64 Runtime. Its installation was not completed. Run this installer again and allow the Microsoft runtime installation. Cloud mode remains available."
    ${EndIf}
    SetOutPath "$INSTDIR"
  ${EndIf}
!macroend
