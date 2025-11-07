param(
    [ValidateSet('Debug', 'Release')][string]$Configuration = 'Release',
    [string]$Platform = 'AnyCPU',
    [ValidateSet('quiet', 'minimal', 'normal', 'detailed', 'diagnostic')][string]$Verbosity = 'minimal',
    [string]$MSBuildPath = '',
    [switch]$Clean,
    [string]$LogPath = '',
    [string]$StageDir = '',
    [string]$ISCCPath = '',
    [switch]$DiagPaths   # print PATHs & where.exe results
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# region: helpers -------------------------------------------------------------
function Write-Header($text) {
    Write-Host "=== $text ===" -ForegroundColor Cyan
}

function Write-Warn($text) {
    Write-Host $text -ForegroundColor Yellow
}

function Resolve-MSBuild {
    param([string]$UserProvided)
    if($UserProvided -and (Test-Path $UserProvided)) {
        return (Resolve-Path $UserProvided).Path
    }
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if(Test-Path $vswhere) {
        try {
            $msbuild = & $vswhere -latest -requires Microsoft.Component.MSBuild -find "MSBuild\**\Bin\MSBuild.exe" | Select-Object -First 1
            if($msbuild -and (Test-Path $msbuild)) {
                return (Resolve-Path $msbuild).Path
            }
        } catch {
            # ignore
        }
    }
    $candidates = @(
        "C:\Program Files\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe",
        "C:\Program Files\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe",
        "C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\MSBuild\Current\Bin\MSBuild.exe",
        "C:\Program Files (x86)\Microsoft Visual Studio\2019\Community\MSBuild\Current\Bin\MSBuild.exe",
        "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\MSBuild.exe"
    )
    foreach($c in $candidates) {
        if(Test-Path $c) {
            return (Resolve-Path $c).Path
        }
    }
    $onPath = (Get-Command msbuild.exe -ErrorAction SilentlyContinue)
    if($onPath) {
        return $onPath.Path
    }
    throw "MSBuild.exe not found. Install Visual Studio Build Tools or specify -MSBuildPath."
}

function Resolve-ISCC {
    param([string]$UserProvided, [switch]$Diag)
    if($UserProvided -and (Test-Path $UserProvided)) {
        return (Resolve-Path $UserProvided).Path
    }
    # 1) PowerShell resolver (PATH)
    $cmd = Get-Command iscc.exe -ErrorAction SilentlyContinue
    if($cmd) {
        return $cmd.Path
    }
    # 2) Try where.exe (mimics CMD PATH lookup; returns all matches)
    try {
        $where = & where.exe iscc.exe 2>$null
        if($Diag) {
            Write-Host "where.exe iscc.exe =>`n$where"
        }
        if($where) {
            foreach($w in ($where -split "`r?`n")) {
                if(Test-Path $w) {
                    return (Resolve-Path $w).Path
                }
            }
        }
    } catch {
        # ignore
    }

    # 3) Common install locations
    $candidates = @(
        "C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
        "C:\Program Files\Inno Setup 6\ISCC.exe",
        "C:\Program Files (x86)\Inno Setup 5\ISCC.exe",
        "C:\Program Files\Inno Setup 5\ISCC.exe"
    )
    foreach($c in $candidates) {
        if(Test-Path $c) {
            return (Resolve-Path $c).Path 
        } 
    }

    # 4) Registry (HKLM + WOW64) — look for Inno Setup entries, use InstallLocation/UninstallString
    $regPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    foreach($rp in $regPaths) {
        try {
            $items = Get-ItemProperty -Path (Join-Path $rp "*") -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like "Inno Setup*" -or $_.DisplayIcon -like "*ISCC.exe*" -or $_.UninstallString -like "*Inno Setup*" }
            foreach($it in $items) {
                $pathsToTry = @()
                if($it.InstallLocation) {
                    $pathsToTry += (Join-Path $it.InstallLocation "ISCC.exe") 
                }
                if($it.DisplayIcon) {
                    $pathsToTry += $it.DisplayIcon 
                }
                if($it.UninstallString) {
                    $dir = Split-Path ($it.UninstallString -replace '"', '') -ErrorAction SilentlyContinue
                    if($dir) {
                        $pathsToTry += (Join-Path $dir "ISCC.exe") 
                    }
                }
                foreach($p in $pathsToTry) {
                    if($p -and (Test-Path $p)) {
                        return (Resolve-Path $p).Path 
                    }
                }
            }
        } catch {
            # ignore
        }
    }
    if($Diag) {
        Write-Host "Process PATH:`n$env:Path"
        $u = [System.Environment]::GetEnvironmentVariable('Path', 'User')
        $m = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
        Write-Host "`nUser PATH:`n$u"
        Write-Host "`nMachine PATH:`n$m"
    }
    throw "ISCC.exe not found. Either add it to PATH, install Inno Setup 6, or pass -ISCCPath."
}
# endregion -------------------------------------------------------------------

# region: path setup ----------------------------------------------------------
$scriptsDir = Split-Path -Parent $PSCommandPath
$projectDir = Split-Path -Parent $scriptsDir
$appsDir = Split-Path -Parent $projectDir
$repoRoot = Split-Path -Parent $appsDir
$projectFile = Join-Path $projectDir 'Recorder.csproj'
$issFile = Join-Path $scriptsDir  'Recorder.iss'
if(-not (Test-Path $projectFile)) {
    throw "Project file not found: $projectFile" 
}
if(-not (Test-Path $issFile)) {
    throw "Installer script not found: $issFile" 
}
# endregion -------------------------------------------------------------------

# region: build project -------------------------------------------------------
Write-Header "Build Recorder ($Configuration)"
$msbuildPath = Resolve-MSBuild -UserProvided $MSBuildPath
Write-Host "MSBuild: $msbuildPath"
Write-Host "Project: $projectFile"

$targets = if($Clean) {
    "Clean;Build" 
} else {
    "Build" 
}
$outDir = Join-Path $projectDir ("bin\{0}" -f $Configuration)

# Build
$msbuildArgs = @($projectFile, "/t:$targets", "/p:Configuration=$Configuration", "/p:Platform=$Platform", "/verbosity:$Verbosity")
Write-Header "Invoking MSBuild"
Write-Host ("CMD: `"{0}`" {1}" -f $msbuildPath, ($msbuildArgs -join ' '))
if([string]::IsNullOrWhiteSpace($LogPath)) {
    & $msbuildPath @msbuildArgs
} else {
    $logDir = Split-Path -Parent $LogPath
    if($logDir -and -not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir | Out-Null 
    }
    & $msbuildPath @msbuildArgs 2>&1 | Tee-Object -FilePath $LogPath
    Write-Host "Log saved to $LogPath"
}
if($LASTEXITCODE -ne 0) {
    throw "MSBuild failed with exit code $LASTEXITCODE." 
}

# Locate build out dir
$exeName = 'Recorder.exe'
$exePath = Join-Path $outDir $exeName
if(-not (Test-Path $exePath)) {
    $platDir = Join-Path $outDir $Platform
    $exeAlt = Join-Path $platDir $exeName
    if(Test-Path $exeAlt) {
        $exePath = $exeAlt 
    }
}
$exeDir = if(Test-Path $exePath) {
    Split-Path -Parent $exePath 
} else {
    $outDir 
}
# endregion -------------------------------------------------------------------

# region: staging -------------------------------------------------------------
Write-Header "Staging build output and dependencies"
if([string]::IsNullOrWhiteSpace($StageDir)) {
    $StageDir = Join-Path $projectDir 'Stage' 
}
if(Test-Path $StageDir) {
    try {
        [System.IO.Directory]::Delete($StageDir, $true)
    } catch {
        Write-Warn "Could not fully clear $StageDir. Continuing... ($($_.Exception.Message))"
    }
}
New-Item -ItemType Directory -Path $StageDir | Out-Null
if(Test-Path $exeDir) {
    Write-Host "Copying build output from: $exeDir"
    Copy-Item -Path (Join-Path $exeDir '*') -Destination $StageDir -Recurse -Force
}
$thirdPartyDir = Join-Path $repoRoot 'ThirdParty'
$configsDir = Join-Path $repoRoot 'Configs'
$deps = @(
    @{ Source = (Join-Path $thirdPartyDir 'ffmpeg.exe'); Dest = (Join-Path $StageDir 'ffmpeg.exe') },
    @{ Source = (Join-Path $thirdPartyDir 'DotNet462'); Dest = (Join-Path $StageDir 'DotNet462') },
    @{ Source = (Join-Path $configsDir    'Recorder.ini'); Dest = (Join-Path $StageDir 'Recorder.ini') }
)
foreach($d in $deps) {
    if(Test-Path $d.Source) {
        if(Test-Path $d.Source -PathType Container) {
            Copy-Item -Path $d.Source -Destination $d.Dest -Recurse -Force
        } else {
            Copy-Item -Path $d.Source -Destination $d.Dest -Force
        }
    } else {
        Write-Warn "Missing dependency: $($d.Source)"
    }
}
# endregion -------------------------------------------------------------------

# region: installer -----------------------------------------------------------
Write-Header "Building installer"
$iscc = Resolve-ISCC -UserProvided $ISCCPath -Diag:$DiagPaths
Write-Host "ISCC: $iscc"
Write-Host "ISS : $issFile"
$installersDir = Join-Path $repoRoot 'Installers'
if(-not (Test-Path $installersDir)) {
    New-Item -ItemType Directory -Path $installersDir | Out-Null 
}

& "$iscc" /DAppVer="1.0.0" /DStageDir="$StageDir" $issFile
# endregion -------------------------------------------------------------------

