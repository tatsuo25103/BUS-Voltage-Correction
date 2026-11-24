Option Explicit

Dim shell, fileSystem, basePath, command
Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

basePath = fileSystem.GetParentFolderName(WScript.ScriptFullName)
command = "powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File """ _
    & basePath & "\BUS_Voltage_Correction.ps1""""

shell.Run command, 0, False
