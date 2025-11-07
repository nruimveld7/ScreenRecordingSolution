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
AppId={{C0F69A0D-07F1-4F9C-9F3E-8F5B6F1C7E47}
AppName=SRS Recorder
AppVersion={#appVer}
AppPublisher=Screen Recording Solution
DefaultDirName={sd}\\SRS\\Recorder
DisableDirPage=yes
DisableProgramGroupPage=yes
OutputBaseFilename=SRSRecorderSetup-{#appVer}
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

[Files]
; Grab EVERYTHING in Stage (including subfolders) and drop into {app}
Source: "{#stageDir}\\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
; Optional Start Menu shortcut (commented out because tray/service apps often don't need it)
; Name: "{group}\\Recorder"; Filename: "{app}\\Recorder.exe"

; Optional desktop shortcut (off by default)
; Name: "{autodesktop}\\Recorder"; Filename: "{app}\\Recorder.exe"; Tasks: desktopicon

; Launch Recorder via common Startup folder for all users
Name: "{commonstartup}\\Recorder"; Filename: "{app}\\Recorder.exe"; WorkingDir: "{app}"; IconFilename: "{app}\\Recorder.exe"; IconIndex: 0

[Run]
; Optionally auto-start Recorder after install (suppressed on silent installs)
Filename: "{app}\\Recorder.exe"; Description: "Launch Recorder"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; Show a console, run Uninstall.bat, and wait
Filename: "{cmd}"; Parameters: "/C ""{app}\DotNet462\Uninstall.bat"""; WorkingDir: "{app}\DotNet462"; Flags: waituntilterminated; Check: NeedDotNet462Uninstall; RunOnceId: DotNet462Cleanup
; Ensure Recorder.exe is closed
Filename: "{sys}\taskkill.exe"; Parameters: "/IM ""Recorder.exe"" /F"; Flags: waituntilterminated; RunOnceId: KillRecorderExe

[UninstallDelete]
Type: filesandordirs; Name: "{app}"

[Code]
const
    dotNetDir = 'DotNet462';
    msiX64 = 'netfx_Full_x64.msi';
    msiX86 = 'netfx_Full_x86.msi';

function IsDotNet462Installed(): Boolean;
var
    release: Cardinal;
    key: string;
begin
    result := False;
    key := 'SOFTWARE\\Microsoft\\NET Framework Setup\\NDP\\v4\\Full';
    if IsWin64 then
    begin
        if RegQueryDWordValue(HKLM64, key, 'Release', release) then
        begin
            Log(Format('[64-bit] .NET Release key: %d', [release]));
            if release >= 394802 then
            begin
                result := True;
            end;
        end else
        begin
            Log('[64-bit] .NET registry key not found.');
        end;
    end else
    begin
        if RegQueryDWordValue(HKLM, key, 'Release', release) then
        begin
            Log(Format('[32-bit] .NET Release key: %d', [release]));
            if release >= 394802 then 
            begin
                result := True;
            end;
        end else
        begin
            Log('[32-bit] .NET registry key not found.');
        end;
    end;
end;


function NeedDotNet462Uninstall(): Boolean;
var
    ScriptPath: string;
begin
    ScriptPath := ExpandConstant('{app}\\' + dotNetDir + '\\Uninstall.bat');
    result := FileExists(ScriptPath);
    if not result then
    begin
        Log('DotNet462 uninstall script not found; skipping.');
    end;
end;

procedure InstallDotNet(const DotNetPath: string);
var
    msiPath: string;
    resultCode: Integer;
    is64Bit: Boolean;
begin
    is64Bit := Is64BitInstallMode;
    if is64Bit then
    begin
        msiPath := DotNetPath + '\\' + msiX64;
    end else
    begin
        msiPath := DotNetPath + '\\' + msiX86;
    end;
    if not FileExists(msiPath) then
    begin
        Log('MSI not found: ' + msiPath);
        exit;
    end;
    Log('Installing .NET Framework 4.6.2 from ' + msiPath);
    // /qn = silent, /norestart = no reboot
    if Exec('msiexec.exe', '/i "' + msiPath + '" /qn /norestart', '', SW_HIDE, ewWaitUntilTerminated, resultCode) then
    begin
        Log('.NET 4.6.2 installer exited with code ' + IntToStr(resultCode));
        if resultCode = 3010 then
        begin
            Log('Reboot requested by .NET installer — ignored.');
        end;
    end else
    begin
        MsgBox('Failed to launch .NET 4.6.2 installer.', mbError, MB_OK);
    end;
end;

// -----------------------------
// Install / Uninstall hooks
// -----------------------------

procedure CurStepChanged(currentStep: TSetupStep);
var
    targetDir: string;
begin
    if currentStep = ssPostInstall then
    begin
        // Ensure .NET 4.6.2 (x86/x64 MSI) is installed before enabling autorun
        targetDir := ExpandConstant('{app}\\' + dotNetDir);
        if IsDotNet462Installed() then
        begin
            Log('.NET Framework 4.6.2 or higher detected - skipping installation.')
        end else
        begin
            if DirExists(targetDir) then
            begin
                Log('Installing .NET Framework 4.6.2 from staged payload.');
                InstallDotNet(targetDir);
            end else
            begin
                Log('DotNet Framework payload not found; skipping .NET installation.');
            end;
        end;
        Log('Recorder will auto-start via the common Startup folder shortcut.');
    end;
end;
