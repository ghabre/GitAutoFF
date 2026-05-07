Set shell = CreateObject("WScript.Shell")
command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & WScript.Arguments(0) & """ -RootPath """ & WScript.Arguments(1) & """ -RetentionDays " & WScript.Arguments(2) & " -CommandTimeoutSeconds " & WScript.Arguments(3)
shell.Run command, 0, False
