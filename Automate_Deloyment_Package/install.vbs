Option Explicit

Dim shell, installerPath, command, exitCode

Set shell = CreateObject("WScript.Shell")

' O instalador deve estar na mesma pasta do script VBS
installerPath = CreateObject("Scripting.FileSystemObject") _
    .BuildPath(CreateObject("Scripting.FileSystemObject") _
    .GetParentFolderName(WScript.ScriptFullName), "Setup.exe")

command = """" & installerPath & """ /silent"

' Parâmetros:
' 0    = janela oculta
' True = aguarda a instalação terminar
exitCode = shell.Run(command, 0, True)

If exitCode = 0 Then
    WScript.Quit 0
Else
    WScript.Quit exitCode
End If