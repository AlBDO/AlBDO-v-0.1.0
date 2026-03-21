/**
 *  EnvVarUpdate.nsh
 *  A NSIS macro to update environment variables
 *
 *  Written by KiCHiK 2010-01-17
 *  Based on work by:
 *   - Vlad Goncharov (EnvVarSet)
 *   - Anders (multiuser support)
 *
 */

!ifndef ENVVARUPDATE_NSH
!define ENVVARUPDATE_NSH

!include "LogicLib.nsh"
!include "WinMessages.NSH"
!include "StrFunc.nsh"

${StrStr}
${StrRep}

!macro _EnvVarUpdate UN OUTVAR ACTION REGVIEW VARNAME VALUE

  Push "${UN}"
  Push "${ACTION}"
  Push "${REGVIEW}"
  Push "${VARNAME}"
  Push "${VALUE}"
  Call ${UN}EnvVarUpdate
  Pop "${OUTVAR}"

!macroend

!define EnvVarUpdate    `!insertmacro _EnvVarUpdate ""`
!define un.EnvVarUpdate `!insertmacro _EnvVarUpdate "un."`

;----------------------------------------------------
; Function (installer)
;----------------------------------------------------
Function EnvVarUpdate

  Push $0
  Push $1
  Push $2
  Push $3
  Push $4
  Push $5
  Push $6
  Push $7
  Push $8
  Push $9

  Exch 9
  Pop $9   ; VALUE
  Exch 9
  Exch 8
  Pop $8   ; VARNAME
  Exch 8
  Exch 7
  Pop $7   ; REGVIEW
  Exch 7
  Exch 6
  Pop $6   ; ACTION
  Exch 6
  Exch 5
  Pop $5   ; UN (unused)
  Exch 5

  StrCmp $7 "HKLM" 0 use_hkcu
    ReadRegStr $0 HKLM "SYSTEM\CurrentControlSet\Control\Session Manager\Environment" $8
    Goto reg_read_done
  use_hkcu:
    ReadRegStr $0 HKCU "Environment" $8
  reg_read_done:

  StrCmp $6 "R" do_remove

  Push $0
  Push $9
  Call EnvVarUpdate_StrStr
  Pop $1
  StrCmp $1 "" not_present
    Goto env_write_done
  not_present:

  StrCmp $6 "P" do_prepend
  StrCmp $0 "" 0 append_sep
    StrCpy $0 $9
    Goto env_write
  append_sep:
    StrCpy $0 "$0;$9"
    Goto env_write

  do_prepend:
  StrCmp $0 "" 0 prepend_sep
    StrCpy $0 $9
    Goto env_write
  prepend_sep:
    StrCpy $0 "$9;$0"
    Goto env_write

  do_remove:
  Push $0
  Push "$9;"
  Push ""
  Call EnvVarUpdate_StrRep
  Pop $0
  Push $0
  Push ";$9"
  Push ""
  Call EnvVarUpdate_StrRep
  Pop $0
  Push $0
  Push $9
  Push ""
  Call EnvVarUpdate_StrRep
  Pop $0

  env_write:
  StrCmp $7 "HKLM" 0 write_hkcu
    WriteRegExpandStr HKLM "SYSTEM\CurrentControlSet\Control\Session Manager\Environment" $8 $0
    Goto notify_change
  write_hkcu:
    WriteRegExpandStr HKCU "Environment" $8 $0
  notify_change:
    SendMessage ${HWND_BROADCAST} ${WM_WININICHANGE} 0 "STR:Environment" /TIMEOUT=5000

  env_write_done:

  Pop $9
  Pop $8
  Pop $7
  Pop $6
  Pop $5
  Pop $4
  Pop $3
  Pop $2
  Pop $1
  Pop $0
  Push $0

FunctionEnd

;----------------------------------------------------
; Function (uninstaller)
;----------------------------------------------------
Function un.EnvVarUpdate

  Push $0
  Push $1
  Push $2
  Push $3
  Push $4
  Push $5
  Push $6
  Push $7
  Push $8
  Push $9

  Exch 9
  Pop $9
  Exch 9
  Exch 8
  Pop $8
  Exch 8
  Exch 7
  Pop $7
  Exch 7
  Exch 6
  Pop $6
  Exch 6
  Exch 5
  Pop $5
  Exch 5

  StrCmp $7 "HKLM" 0 un_use_hkcu
    ReadRegStr $0 HKLM "SYSTEM\CurrentControlSet\Control\Session Manager\Environment" $8
    Goto un_reg_read_done
  un_use_hkcu:
    ReadRegStr $0 HKCU "Environment" $8
  un_reg_read_done:

  Push $0
  Push "$9;"
  Push ""
  Call un.EnvVarUpdate_StrRep
  Pop $0
  Push $0
  Push ";$9"
  Push ""
  Call un.EnvVarUpdate_StrRep
  Pop $0
  Push $0
  Push $9
  Push ""
  Call un.EnvVarUpdate_StrRep
  Pop $0

  StrCmp $7 "HKLM" 0 un_write_hkcu
    WriteRegExpandStr HKLM "SYSTEM\CurrentControlSet\Control\Session Manager\Environment" $8 $0
    Goto un_notify
  un_write_hkcu:
    WriteRegExpandStr HKCU "Environment" $8 $0
  un_notify:
    SendMessage ${HWND_BROADCAST} ${WM_WININICHANGE} 0 "STR:Environment" /TIMEOUT=5000

  Pop $9
  Pop $8
  Pop $7
  Pop $6
  Pop $5
  Pop $4
  Pop $3
  Pop $2
  Pop $1
  Pop $0
  Push $0

FunctionEnd

;----------------------------------------------------
; StrStr helper
;----------------------------------------------------
Function EnvVarUpdate_StrStr
  Exch $R1
  Exch
  Exch $R0
  Push $R2
  Push $R3
  Push $R4

  StrLen $R3 $R1
  StrCpy $R4 ""
  loop:
    StrCpy $R2 $R0 $R3
    StrCmp $R2 $R1 found
    StrCmp $R0 "" done
    StrCpy $R0 $R0 "" 1
    Goto loop
  found:
    StrCpy $R4 $R0
  done:

  Pop $R4
  Pop $R3
  Pop $R2
  Pop $R1
  Exch $R0
FunctionEnd

;----------------------------------------------------
; StrRep helpers
;----------------------------------------------------
Function EnvVarUpdate_StrRep
  Exch $R2
  Exch
  Exch $R1
  Exch 2
  Exch $R0
  Push $R3
  Push $R4
  Push $R5
  Push $R6

  StrLen $R3 $R1
  StrCpy $R4 ""
  StrCpy $R6 $R0
  loop2:
    StrCpy $R5 $R6 $R3
    StrCmp $R5 $R1 do_replace
    StrCmp $R6 "" done2
    StrCpy $R5 $R6 1
    StrCpy $R4 "$R4$R5"
    StrCpy $R6 $R6 "" 1
    Goto loop2
  do_replace:
    StrCpy $R4 "$R4$R2"
    StrCpy $R6 $R6 "" $R3
    Goto loop2
  done2:

  StrCpy $R0 $R4
  Pop $R6
  Pop $R5
  Pop $R4
  Pop $R3
  Pop $R2
  Pop $R1
  Exch $R0
FunctionEnd

Function un.EnvVarUpdate_StrRep
  Exch $R2
  Exch
  Exch $R1
  Exch 2
  Exch $R0
  Push $R3
  Push $R4
  Push $R5
  Push $R6

  StrLen $R3 $R1
  StrCpy $R4 ""
  StrCpy $R6 $R0
  un_loop2:
    StrCpy $R5 $R6 $R3
    StrCmp $R5 $R1 un_do_replace
    StrCmp $R6 "" un_done2
    StrCpy $R5 $R6 1
    StrCpy $R4 "$R4$R5"
    StrCpy $R6 $R6 "" 1
    Goto un_loop2
  un_do_replace:
    StrCpy $R4 "$R4$R2"
    StrCpy $R6 $R6 "" $R3
    Goto un_loop2
  un_done2:

  StrCpy $R0 $R4
  Pop $R6
  Pop $R5
  Pop $R4
  Pop $R3
  Pop $R2
  Pop $R1
  Exch $R0
FunctionEnd

!endif ; ENVVARUPDATE_NSH
