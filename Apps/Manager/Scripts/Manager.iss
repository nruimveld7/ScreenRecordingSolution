#ifndef appVer
    #define appVer "1.0.0"
#endif

#ifndef stageDir
    #define stageDir sourcePath + "..\\..\\Stage"
#endif

#ifndef outputDir
    #define outputDir sourcePath + "..\\..\\..\\Installers"
#endif

[Setup]
AppId={{E1D7E3C1-4A06-4760-8F7B-0C778FE3E1AF}
AppName=SRS Manager
AppVersion={#appVer}
AppPublisher=Screen Recording Solution
DefaultDirName={sd}\\SRS\\Manager
DisableDirPage=yes
DisableProgramGroupPage=yes
OutputBaseFilename=SRSManagerSetup-{#appVer}
OutputDir={#outputDir}
Compression=lzma2
SolidCompression=yes
PrivilegesRequired=admin
SetupLogging=yes
UninstallDisplayIcon={app}\Manager.exe
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Dirs]
Name: "{sd}\SRS"; Flags: uninsneveruninstall
Name: "{app}\Recordings"; Flags: uninsalwaysuninstall

[Files]
; Grab EVERYTHING in Stage (including subfolders) and drop into {app}
Source: "{#stageDir}\\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion; BeforeInstall: StopSRSManager

[Icons]
; Optional Start Menu shortcut (commented out because tray/service apps often don't need it)
; Name: "{group}\\SRS Manager"; Filename: "{app}\\Manager.exe"

; Optional desktop shortcut (off by default)
; Name: "{autodesktop}\\SRS Manager"; Filename: "{app}\\Manager.exe"; Tasks: desktopicon

[Run]
; Ensure base directory exists (redundant with [Dirs] but harmless)
Filename: "{cmd}"; Parameters: "/c if not exist ""{app}\Recordings"" mkdir ""{app}\Recordings"""; Flags: runhidden waituntilterminated

; Remove any existing "Recordings" share then create a fresh one
Filename: "{cmd}"; Parameters: "/c net share ""Recordings"" /DELETE >nul 2>&1 || exit /b 0"; Flags: runhidden waituntilterminated
Filename: "{cmd}"; Parameters: "/c net share ""Recordings""=""{app}\Recordings"" /GRANT:Administrators,FULL /GRANT:""Authenticated Users"",CHANGE /CACHE:None"; Flags: runhidden waituntilterminated

; Replace existing service (if present)
Filename: "{cmd}"; Parameters: "/c sc.exe stop ""SRSManager"" >nul 2>&1 || exit /b 0"; Flags: runhidden waituntilterminated
Filename: "{cmd}"; Parameters: "/c sc.exe delete ""SRSManager"" >nul 2>&1 || exit /b 0"; Flags: runhidden waituntilterminated

; Create and start service
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -Command ""$ErrorActionPreference='Stop'; New-Service -Name 'SRSManager' -BinaryPathName '""{app}\Manager.exe"" --service' -DisplayName 'SRS Manager' -Description 'Receives and stores screen recordings from remote recorder agents.' -StartupType Automatic"""; Flags: runhidden waituntilterminated
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -Command ""$ErrorActionPreference='Stop'; Start-Service -Name 'SRSManager'"""; Flags: runhidden waituntilterminated

[UninstallRun]
Filename: "{cmd}"; Parameters: "/c sc.exe stop ""SRSManager"" >nul 2>&1 || exit /b 0"; Flags: runhidden waituntilterminated; RunOnceId: StopSRSManagerService
Filename: "{cmd}"; Parameters: "/c taskkill /IM ""Manager.exe"" /F >nul 2>&1 || exit /b 0"; Flags: runhidden waituntilterminated; RunOnceId: KillSRSManagerProcesses
Filename: "{cmd}"; Parameters: "/c sc.exe delete ""SRSManager"" >nul 2>&1 || exit /b 0"; Flags: runhidden waituntilterminated; RunOnceId: DeleteSRSManagerService
; /Y suppresses the confirmation prompt if the share is in use so the uninstaller can't hang waiting for input
Filename: "{cmd}"; Parameters: "/c net share ""Recordings"" /DELETE /Y >nul 2>&1 || exit /b 0"; Flags: runhidden waituntilterminated; RunOnceId: RemoveSRSRecordingShare
Filename: "{cmd}"; Parameters: "/c if exist ""{app}"" rd /s /q ""{app}"""; Flags: runhidden waituntilterminated; RunOnceId: RemoveSRSManagerDirectory

[Code]
var
    serviceStopAttempted: Boolean;

function ServiceIsRunning(const serviceName: string): Boolean;
var
    resultCode: Integer;
begin
    result := False;
    if Exec(ExpandConstant('{cmd}'), Format('/c sc.exe query "%s" | find "RUNNING" >nul', [serviceName]), '', SW_HIDE, ewWaitUntilTerminated, resultCode) then
    begin
        result := resultCode = 0;
    end;
end;

procedure StopSRSManager;
var
    resultCode: Integer;
    attempts: Integer;
begin
    if serviceStopAttempted then
    begin
        Exit;
    end;
    serviceStopAttempted := True;
    Log('Stopping existing SRSManager service (if present) before installing files.');
    Exec(ExpandConstant('{cmd}'), '/c sc.exe stop "SRSManager" >nul 2>&1 || exit /b 0', '', SW_HIDE, ewWaitUntilTerminated, resultCode);
    for attempts := 1 to 30 do
    begin
        if not ServiceIsRunning('SRSManager') then
        begin
            Break;
        end;
        Sleep(500);
    end;
    Exec(ExpandConstant('{cmd}'), '/c taskkill /IM "Manager.exe" /F >nul 2>&1 || exit /b 0', '', SW_HIDE, ewWaitUntilTerminated, resultCode);
end;
