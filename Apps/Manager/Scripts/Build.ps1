param(
    [ValidateSet('Debug', 'Release')][string]$Configuration = 'Release',
    [string]$PythonPath = '',
    [switch]$Clean,
    [string]$StageDir = '',
    [string]$ISCCPath = '',
    [switch]$DiagPaths,
    [string]$AppVersion = '1.0.0'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Header($text) {
    Write-Host "=== $text ===" -ForegroundColor Cyan 
}
function Write-Warn($text) {
    Write-Host $text -ForegroundColor Yellow 
}

# region: helpers -------------------------------------------------------------
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

    if($Diag) {
        Write-Host "Process PATH:`n$env:Path"
        $u = [System.Environment]::GetEnvironmentVariable('Path', 'User')
        $m = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
        Write-Host "`nUser PATH:`n$u"
        Write-Host "`nMachine PATH:`n$m"
    }

    throw "ISCC.exe not found. Either add it to PATH, install Inno Setup 6, or pass -ISCCPath."
}

function Sync-Directory([string]$Path) {
    if(-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function Remove-Directory([string]$Path) {
    if(Test-Path $Path) {
        try {
            [System.IO.Directory]::Delete($Path, $true)
        } catch {
            Write-Warn "Unable to fully delete '$Path' ($($_.Exception.Message))."
        }
    }
}
# endregion -------------------------------------------------------------------

# region: path setup ----------------------------------------------------------
$scriptsDir = Split-Path -Parent $PSCommandPath
$projectDir = Split-Path -Parent $scriptsDir
$appsDir = Split-Path -Parent $projectDir
$repoRoot = Split-Path -Parent $appsDir

$requirements = Join-Path $projectDir 'requirements.txt'
$mainPy = Join-Path $projectDir 'main.py'
$issFile = Join-Path $scriptsDir  'Manager.iss'

if(-not (Test-Path $mainPy)) {
    throw "Missing main.py at $mainPy" 
}
if(-not (Test-Path $issFile)) {
    throw "Installer script not found: $issFile" 
}

$venvDir = Join-Path $projectDir '.venv'
$venvPyExe = Join-Path $venvDir 'Scripts\python.exe'
$distDir = Join-Path $projectDir ("bin\{0}" -f $Configuration)
$objDir = Join-Path $projectDir ("obj\{0}" -f $Configuration)
$stageRoot = if([string]::IsNullOrWhiteSpace($StageDir)) {
    Join-Path $projectDir 'Stage' 
} else {
    $StageDir 
}
$pyiWork = Join-Path $objDir 'pyinstaller'

$managerIni = Join-Path $repoRoot 'Configs\Manager.ini'
if(-not (Test-Path $managerIni)) {
    throw "Default Manager.ini not found at $managerIni"
}

$iconPath = Join-Path $repoRoot 'Assets\Icons\Icon.ico'
if(-not (Test-Path $iconPath)) {
    throw "Application icon not found at $iconPath"
}
# endregion -------------------------------------------------------------------

# region: python / dependencies ----------------------------------------------
function Get-PythonExecutable {
    param([string]$UserSpecified)

    if($UserSpecified) {
        if(-not (Test-Path $UserSpecified)) {
            throw "Provided PythonPath not found: $UserSpecified" 
        }
        return (Resolve-Path $UserSpecified).Path
    }

    if(-not (Test-Path $venvPyExe)) {
        Write-Header "Creating project virtual environment (.venv)"
        $pyLauncher = Get-Command py.exe -ErrorAction SilentlyContinue
        if($pyLauncher) {
            & $pyLauncher.Path -3 -m venv $venvDir
        } elseif(Get-Command python.exe -ErrorAction SilentlyContinue) {
            & (Get-Command python.exe).Path -m venv $venvDir
        } else {
            throw "Python 3 not found. Install Python 3 or pass -PythonPath."
        }
    }

    if(-not (Test-Path $venvPyExe)) {
        throw "Virtual environment creation failed: $venvPyExe not found." 
    }
    return (Resolve-Path $venvPyExe).Path
}

$pythonExe = Get-PythonExecutable -UserSpecified $PythonPath
Write-Header "Using Python"
Write-Host "Python: $pythonExe"

Write-Header "Installing Python dependencies"
& $pythonExe -m pip install --upgrade pip
if(Test-Path $requirements) {
    & $pythonExe -m pip install -r $requirements
}
& $pythonExe -m pip install pyinstaller
# endregion -------------------------------------------------------------------

# region: clean / prepare folders --------------------------------------------
if($Clean) {
    Write-Header "Cleaning previous outputs"
    foreach($dir in @($distDir, $objDir, $stageRoot)) {
        Remove-Directory $dir
    }
}

Sync-Directory $distDir
Sync-Directory $objDir
Sync-Directory $pyiWork
# endregion -------------------------------------------------------------------

# region: build executable ----------------------------------------------------
$exeName = 'Manager.exe'
$pyinstallerArgs = @(
    '-m', 'PyInstaller',
    $mainPy,
    '--clean',
    '--noconfirm',
    '--workpath', $pyiWork,
    '--specpath', $pyiWork,
    '--distpath', $distDir,
    '--icon', $iconPath,
    '--hidden-import', 'win32timezone',
    '--hidden-import', 'pywintypes',
    '--hidden-import', 'pythoncom',
    '--name', [System.IO.Path]::GetFileNameWithoutExtension($exeName),
    '--onefile',
    '--console'
)

Write-Header "Running PyInstaller"
Push-Location $projectDir
try {
    & $pythonExe @pyinstallerArgs
    if($LASTEXITCODE -ne 0) {
        throw "PyInstaller exited with code $LASTEXITCODE." 
    }
} finally {
    Pop-Location
}

$builtExe = Join-Path $distDir $exeName
if(-not (Test-Path $builtExe)) {
    throw "Expected executable not found at $builtExe"
}
# endregion -------------------------------------------------------------------

# region: staging -------------------------------------------------------------
Write-Header "Staging runtime payload"
if(Test-Path $stageRoot) {
    Remove-Directory $stageRoot
}
Sync-Directory $stageRoot

Copy-Item -Path $builtExe -Destination (Join-Path $stageRoot $exeName) -Force
Copy-Item -Path $managerIni -Destination (Join-Path $stageRoot 'Manager.ini') -Force
# endregion -------------------------------------------------------------------

# region: installer -----------------------------------------------------------
Write-Header "Packing installer"
$iscc = Resolve-ISCC -UserProvided $ISCCPath -Diag:$DiagPaths
Write-Host "ISCC : $iscc"
Write-Host "ISS  : $issFile"

$installersDir = Join-Path $repoRoot 'Installers'
Sync-Directory $installersDir

& $iscc `
    "/DAppVer=$AppVersion" `
    "/DStageDir=$stageRoot" `
    "/DOutputDir=$installersDir" `
    $issFile

if($LASTEXITCODE -ne 0) {
    throw "ISCC failed with exit code $LASTEXITCODE." 
}
# endregion -------------------------------------------------------------------

Write-Header "Manager build complete"

