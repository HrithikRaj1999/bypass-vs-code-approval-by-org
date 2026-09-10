' Starts approval-auto in the background with no console window at all.
' Double-click this file, or drop a shortcut to it in shell:startup to have it
' run at logon. Quit it from its tray icon: right-click -> Exit.

Option Explicit

Dim shell, folder, script, cmd
Set shell = CreateObject("WScript.Shell")

folder = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
script = folder & "approval-auto.ps1"

' -IncludeOffscreen : also press buttons scrolled out of view.
'
' -IncludeAmbiguous is deliberately NOT set. It adds bare Run / Accept /
' Continue / Keep Going, which are not approval buttons - the debug toolbar,
' test explorer and merge editor use those exact labels. With it enabled this
' clicked the VS Code menu bar "Run" menu 13 times in 13 seconds. The 44
' default rules already cover every real approval prompt.
' -NoCursor : never drive the real mouse. Clicks are posted to the window, so
'             the pointer never moves and focus is never taken while you type.
'             Falls back to a real click only if a posted one does not land.
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & script & """" & _
      " -Background -IncludeOffscreen -NoCursor"

' 0 = hidden window, False = do not wait for it to finish
shell.Run cmd, 0, False
