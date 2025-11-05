#ifndef AppVer
  #define AppVer "1.0.0"
#endif

#ifndef StageDir
  ; Fallback if not passed from command line
  #define StageDir SourcePath + "..\\..\\Stage"
#endif

#ifndef OutputDir
  #define OutputDir SourcePath + "..\\..\\..\\Installers"
#endif

#ifndef TaskName
  #define TaskName "Recorder"
#endif

[Setup]
AppId={{C0F69A0D-07F1-4F9C-9F3E-8F5B6F1C7E47}
AppName=Recorder
AppVersion={#AppVer}
AppPublisher=Screen Recording Solution
DefaultDirName={sd}\\Recorder
DisableDirPage=yes
DisableProgramGroupPage=yes
OutputBaseFilename=RecorderSetup
OutputDir={#OutputDir}
Compression=lzma2
SolidCompression=yes
PrivilegesRequired=admin
SetupLogging=yes
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
; Add tasks here if you later want shortcuts/services, etc.

[Files]
; Grab EVERYTHING in Stage (including subfolders) and drop into {app}
; If you need to exclude something (e.g., symbols or zips), add "Excludes:" below.
Source: "{#StageDir}\\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

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

; If you want to delete extra files created after install, specify here.
; Type: filesandordirs; Name: "{app}\\Logs"

[UninstallRun]
; Show a console, run Uninstall.bat, and wait
Filename: "{cmd}"; Parameters: "/C ""{app}\DotNet462\Uninstall.bat"""; WorkingDir: "{app}\DotNet462"; Flags: waituntilterminated; Check: NeedDotNet462Uninstall; RunOnceId: DotNet462Cleanup
; Ensure Recorder.exe is closed
Filename: "{sys}\taskkill.exe"; Parameters: "/IM ""Recorder.exe"" /F"; Flags: waituntilterminated; RunOnceId: KillRecorderExe

[UninstallDelete]
Type: filesandordirs; Name: "{app}"

[Code]
const
  DotNetDir = 'DotNet462';
  MsiX64    = 'netfx_Full_x64.msi';
  MsiX86    = 'netfx_Full_x86.msi';

function IsDotNet462Installed(): Boolean;
var
  Release: Cardinal;
  Key: string;
begin
  Result := False;
  Key := 'SOFTWARE\\Microsoft\\NET Framework Setup\\NDP\\v4\\Full';

  if IsWin64 then begin
    if RegQueryDWordValue(HKLM64, Key, 'Release', Release) then begin
      Log(Format('[64-bit] .NET Release key: %d', [Release]));
      if Release >= 394802 then Result := True;
    end else
      Log('[64-bit] .NET registry key not found.');
  end else begin
    if RegQueryDWordValue(HKLM, Key, 'Release', Release) then begin
      Log(Format('[32-bit] .NET Release key: %d', [Release]));
      if Release >= 394802 then Result := True;
    end else
      Log('[32-bit] .NET registry key not found.');
  end;
end;


function NeedDotNet462Uninstall(): Boolean;
var
  ScriptPath: string;
begin
  ScriptPath := ExpandConstant('{app}\\' + DotNetDir + '\\Uninstall.bat');
  Result := FileExists(ScriptPath);
  if not Result then
    Log('DotNet462 uninstall script not found; skipping.');
end;

procedure InstallDotNet(const DotNetPath: string);
var
  MsiPath: string;
  ResultCode: Integer;
  Is64Bit: Boolean;
begin
  Is64Bit := Is64BitInstallMode;
  if Is64Bit then
    MsiPath := DotNetPath + '\\' + MsiX64
  else
    MsiPath := DotNetPath + '\\' + MsiX86;

  if not FileExists(MsiPath) then begin
    Log('MSI not found: ' + MsiPath);
    exit;
  end;

  Log('Installing .NET Framework 4.6.2 from ' + MsiPath);
  // /qn = silent, /norestart = no reboot
  if Exec('msiexec.exe', '/i "' + MsiPath + '" /qn /norestart', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then begin
    Log('.NET 4.6.2 installer exited with code ' + IntToStr(ResultCode));
    if ResultCode = 3010 then
      Log('Reboot requested by .NET installer — ignored.');
  end else
    MsgBox('Failed to launch .NET 4.6.2 installer.', mbError, MB_OK);
end;

// -----------------------------
// Install / Uninstall hooks
// -----------------------------

procedure CurStepChanged(CurStep: TSetupStep);
var
  TargetDir: string;
begin
  if CurStep = ssPostInstall then begin
    // Ensure .NET 4.6.2 (x86/x64 MSI) is installed before enabling autorun
    TargetDir := ExpandConstant('{app}\\' + DotNetDir);

    if IsDotNet462Installed() then
      Log('.NET Framework 4.6.2 or higher detected - skipping installation.')
    else begin
      if DirExists(TargetDir) then begin
        Log('Installing .NET Framework 4.6.2 from staged payload.');
        InstallDotNet(TargetDir);
      end else begin
        Log('DotNet Framework payload not found; skipping .NET installation.');
      end;
    end;

    Log('Recorder will auto-start via the common Startup folder shortcut.');
  end;
end;


