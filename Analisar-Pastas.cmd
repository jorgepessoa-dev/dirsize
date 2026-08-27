@echo off
rem ---------------------------------------------------------------------------
rem  Lancador de duplo-clique para Analyze-FolderSizes.ps1
rem  Sem argumentos  -> abre a janela para escolher a pasta (com historico).
rem  Com argumentos   -> sao passados ao script tal e qual.
rem     Ex:  Analisar-Pastas.cmd -Path "\\servidor\share" -HtmlOut rel.html
rem  Nao altera a ExecutionPolicy do sistema. Nao precisa de administrador.
rem ---------------------------------------------------------------------------
setlocal
set "HERE=%~dp0"

rem  Remove a marca "ficheiro da Internet" (MOTW) dos ficheiros da pasta. Sob uma
rem  GPO corporativa (MachinePolicy = RemoteSigned) o -ExecutionPolicy Bypass e
rem  ignorado, e so o Unblock-File permite correr um .ps1 descarregado.
powershell.exe -NoProfile -Command "Get-ChildItem -Path '%HERE%*.ps1' | Unblock-File" 1>nul 2>nul

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%HERE%Analyze-FolderSizes.ps1" %*
set "RC=%ERRORLEVEL%"
rem  RC=2 = scan cancelado (resultados parciais). So faz pausa se algo correu mal.
if %RC% GEQ 3 (
  echo.
  echo O script terminou com erro ^(codigo %RC%^).
  pause
)
endlocal
