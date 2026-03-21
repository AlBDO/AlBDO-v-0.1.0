; ============================================================
;  Albedo — NSIS Installer Script
;  Place icon at: B:\beta-two\assets\icon.ico before compiling
; ============================================================

;------------------------------------------------------------
; Modern UI + EnvVarUpdate for PATH manipulation
;------------------------------------------------------------
!include "MUI2.nsh"
!include "EnvVarUpdate.nsh"   ; local copy in project root

;------------------------------------------------------------
; Metadata
;------------------------------------------------------------
Name              "Albedo"
OutFile           "Albedo-Setup.exe"
InstallDir        "$PROGRAMFILES64\Albedo"
InstallDirRegKey  HKLM "Software\Albedo" "InstallDir"
RequestExecutionLevel admin
Unicode True

VIProductVersion                   "0.1.0.0"
VIAddVersionKey "ProductName"      "Albedo"
VIAddVersionKey "ProductVersion"   "0.1.0"
VIAddVersionKey "FileDescription"  "Albedo Installer"
VIAddVersionKey "LegalCopyright"   "2025"


;------------------------------------------------------------
; Appearance — Minimalist & Clean
;------------------------------------------------------------
!define MUI_ICON                        "assets\icon.ico"
!define MUI_UNICON                      "assets\icon.ico"
!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_NOAUTOCLOSE
!define MUI_WELCOMEPAGE_TITLE           "Albedo Setup"
!define MUI_WELCOMEPAGE_TEXT            "This will install Albedo on your computer.$\r$\n$\r$\nClick Next to continue."
!define MUI_FINISHPAGE_TITLE            "Installation Complete"
!define MUI_FINISHPAGE_TEXT             "Albedo has been installed successfully."
!define MUI_PAGE_HEADER_TEXT            ""
!define MUI_PAGE_HEADER_SUBTEXT         ""



;------------------------------------------------------------
; Pages
;------------------------------------------------------------
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
Page custom PathPage PathPageLeave
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

;------------------------------------------------------------
; Language (must come after pages)
;------------------------------------------------------------
!insertmacro MUI_LANGUAGE "English"

;------------------------------------------------------------
; Variable to track the PATH checkbox state
;------------------------------------------------------------
Var AddToPath


;------------------------------------------------------------
; Custom PATH Page
;------------------------------------------------------------
Function PathPage
    nsDialogs::Create 1018
    Pop $0

    ${NSD_CreateLabel} 0 15u 100% 12u "Additional Options"
    Pop $0

    ${NSD_CreateCheckbox} 0 35u 100% 12u "Add Albedo to the PATH environment variable (recommended)"
    Pop $0
    ${NSD_SetState} $0 ${BST_CHECKED}
    StrCpy $AddToPath "1"

    GetFunctionAddress $1 OnPathCheckboxToggle
    nsDialogs::OnClick $0 $1

    nsDialogs::Show
FunctionEnd

Function OnPathCheckboxToggle
    Pop $0
    ${NSD_GetState} $0 $AddToPath
FunctionEnd

Function PathPageLeave
    ; $AddToPath is already set via the checkbox callback
FunctionEnd


;------------------------------------------------------------
; Main Install Section
;------------------------------------------------------------
Section "Core" SEC_CORE
    SectionIn RO   ; always required

    SetOutPath "$INSTDIR"
    File "target\release\albedo.exe"

    ; Write the uninstaller
    WriteUninstaller "$INSTDIR\Uninstall.exe"

    ; Add to Windows Add/Remove Programs
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Albedo" \
                     "DisplayName" "Albedo"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Albedo" \
                     "UninstallString" '"$INSTDIR\Uninstall.exe"'
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Albedo" \
                     "DisplayVersion" "0.1.0"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Albedo" \
                     "Publisher" "Your Name"
    WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Albedo" \
                     "DisplayIcon" "$INSTDIR\albedo.exe"
    WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Albedo" \
                       "NoModify" 1
    WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Albedo" \
                       "NoRepair" 1

    ; Optionally add to PATH
    ${If} $AddToPath == "1"
        ${EnvVarUpdate} $0 "PATH" "A" "HKLM" "$INSTDIR"
    ${EndIf}

SectionEnd


;------------------------------------------------------------
; Uninstaller
;------------------------------------------------------------
Section "Uninstall"

    ; Remove binary and uninstaller
    Delete "$INSTDIR\albedo.exe"
    Delete "$INSTDIR\Uninstall.exe"
    RMDir  "$INSTDIR"

    ; Remove from PATH
    ${un.EnvVarUpdate} $0 "PATH" "R" "HKLM" "$INSTDIR"

    ; Clean up registry
    DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\Albedo"
    DeleteRegKey HKLM "Software\Albedo"

SectionEnd
