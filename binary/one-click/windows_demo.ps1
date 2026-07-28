# =============================================================================
# Development environment setup script (Windows / PowerShell)
# Clones registry-center & orchestration-center, creates venvs, and starts all services.
# Prerequisites: python 3.12+, node/npm, git
#
# To run this script:
#   powershell -ExecutionPolicy Bypass -File windows_demo.ps1
# Or in a PowerShell session:
#   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#   .\windows_demo.ps1
# =============================================================================
$ErrorActionPreference = "Stop"
$OutputEncoding = [System.Text.Encoding]::UTF8

# Enable Python UTF-8 mode globally (fixes Windows encoding issues with file I/O)
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"

$SCRIPT_DIR = $PSScriptRoot
$WORK_DIR = $SCRIPT_DIR

$REGISTRY_REPO = "https://github.com/project-openan/registry-center.git"
$ORCHESTRATION_REPO = "https://github.com/project-openan/orchestration-center.git"

$REGISTRY_DIR = Join-Path $WORK_DIR "registry-center"
$ORCHESTRATION_DIR = Join-Path $WORK_DIR "orchestration-center"

$CERT_PASSWORD = "Dev@12345"
$FRONTEND_PORT = 3003

# -----------------------------------------------------------------------------
# Helper: check exit code of native commands (git, npm, etc.)
# PowerShell's $ErrorActionPreference="Stop" does NOT apply to external EXEs,
# so we must manually check $LASTEXITCODE after each native command.
# -----------------------------------------------------------------------------
function Invoke-NativeCommand {
    param([scriptblock]$ScriptBlock, [string]$Description = "")
    & $ScriptBlock
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed (exit code $LASTEXITCODE): $Description"
    }
}

# -----------------------------------------------------------------------------
# Helper: kill any process listening on a given TCP port.
# Prevents leftover processes from a previous run causing PID mismatches.
# -----------------------------------------------------------------------------
function Free-Port {
    param([int]$Port)
    $conns = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if ($conns) {
        foreach ($conn in $conns) {
            $procId = $conn.OwningProcess
            Write-Host "  [WARN] Port $Port is in use, killing PID: $procId..."
            Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Seconds 1
    }
}

# -----------------------------------------------------------------------------
# Helper: find a working Python command.
# On Windows, typing 'python' may trigger the Microsoft Store App Execution Alias
# which hangs silently. We try 'py -3' (official launcher) first, then 'python',
# then 'python3', verifying each actually returns a version string.
# -----------------------------------------------------------------------------
function Find-PythonCommand {
    $candidates = @(
        @{ Exe = "py";       Args = @("-3") },
        @{ Exe = "python";  Args = @() },
        @{ Exe = "python3"; Args = @() }
    )
    foreach ($c in $candidates) {
        $testPath = Get-Command $c.Exe -ErrorAction SilentlyContinue
        if (-not $testPath) { continue }

        # Skip the Microsoft Store alias stub
        if ($testPath.Source -match "WindowsApps") {
            Write-Host "  [WARN] Found '$($c.Exe)' in WindowsApps (Store alias), skipping..."
            continue
        }

        # Verify it actually runs
        try {
            $versionOutput = & $c.Exe @($c.Args + @("--version")) 2>&1
            if ($LASTEXITCODE -eq 0 -and $versionOutput -match "Python") {
                Write-Host "  [OK] Using Python: $versionOutput"
                if ($c.Args.Count -gt 0) {
                    return @{ Exe = $c.Exe; Args = $c.Args }
                }
                return @{ Exe = $c.Exe; Args = @() }
            }
        } catch {
            # Command exists but failed to run, try next
        }
    }
    throw @"
Python 3 was not found. Please install Python 3.12+ from https://www.python.org/downloads/
Make sure to check 'Add Python to PATH' during installation.
If you already installed it, disable the Microsoft Store 'App Execution Alias' for Python
in Settings > Apps > Advanced app settings > App execution aliases.
"@
}

# =============================================================================
# Step 1: Clone repositories
# =============================================================================
Write-Host "=========================================="
Write-Host " Step 1: Cloning repositories"
Write-Host "=========================================="

if (Test-Path "$REGISTRY_DIR\.git") {
    Write-Host "[SKIP] registry-center already exists, pulling latest..."
    Invoke-NativeCommand { git -C $REGISTRY_DIR pull --ff-only 2>&1 | Out-Null } "git pull registry-center"
} else {
    Write-Host "[CLONE] registry-center..."
    Invoke-NativeCommand { git clone $REGISTRY_REPO $REGISTRY_DIR } "git clone registry-center"
    if (-not (Test-Path "$REGISTRY_DIR\.git")) {
        throw "git clone seemed to succeed but $REGISTRY_DIR does not exist."
    }
}

if (Test-Path "$ORCHESTRATION_DIR\.git") {
    Write-Host "[SKIP] orchestration-center already exists, pulling latest..."
    Invoke-NativeCommand { git -C $ORCHESTRATION_DIR pull --ff-only 2>&1 | Out-Null } "git pull orchestration-center"
} else {
    Write-Host "[CLONE] orchestration-center..."
    Invoke-NativeCommand { git clone $ORCHESTRATION_REPO $ORCHESTRATION_DIR } "git clone orchestration-center"
    if (-not (Test-Path "$ORCHESTRATION_DIR\.git")) {
        throw "git clone seemed to succeed but $ORCHESTRATION_DIR does not exist."
    }
}

# =============================================================================
# Step 2: Setup registry-center
# =============================================================================
Write-Host ""
Write-Host "=========================================="
Write-Host " Step 2: Setting up registry-center"
Write-Host "=========================================="

$REG_VENV_PYTHON = Join-Path $REGISTRY_DIR "venv\Scripts\python.exe"

# Create venv
if (-not (Test-Path $REG_VENV_PYTHON)) {
    Write-Host "[VENV] Creating virtual environment..."
    $pyCmd = Find-PythonCommand
    Write-Host "  [VENV] Running: $($pyCmd.Exe) $($pyCmd.Args -join ' ') -m venv venv"
    Push-Location $REGISTRY_DIR
    Invoke-NativeCommand { & $pyCmd.Exe @($pyCmd.Args + @("-m", "venv", "venv")) } "venv creation (registry-center)"
    Pop-Location
    if (-not (Test-Path $REG_VENV_PYTHON)) {
        throw "venv creation finished but $REG_VENV_PYTHON was not found."
    }
} else {
    Write-Host "[SKIP] venv already exists."
}

# Install dependencies
Write-Host "[PIP] Installing registry-center dependencies..."
Invoke-NativeCommand { & $REG_VENV_PYTHON -m pip install --upgrade pip } "pip upgrade (registry-center)"
Invoke-NativeCommand { & $REG_VENV_PYTHON -m pip install -r (Join-Path $REGISTRY_DIR "requirements.txt") } "pip install requirements (registry-center)"

# Generate self-signed certificate (serverAuth)
Write-Host "[CERT] Generating self-signed certificates..."
$CERT_DIR = Join-Path $REGISTRY_DIR "etc\cert"
New-Item -ItemType Directory -Path $CERT_DIR -Force | Out-Null

# Use forward slashes for Python string literals
$certDirPy = $CERT_DIR -replace '\\', '/'
$certScript = @"
import sys
sys.path.insert(0, '.')
from common.cert.certificate_generator import CertificateGenerator

generator = CertificateGenerator(key_algorithm='RSA')
if generator.generate_self_signed_cert('$certDirPy', 'serverAuth', '$CERT_PASSWORD'):
    print('  [OK] Self-signed certificate generated in $certDirPy')
else:
    print('  [SKIP] Certificate already exists')
"@

# Write to temp file to avoid multi-line argument issues on Windows
$tempCertScript = Join-Path $env:TEMP "openan_cert_gen.py"
$certScript | Out-File -FilePath $tempCertScript -Encoding UTF8 -Force
Push-Location $REGISTRY_DIR
& $REG_VENV_PYTHON $tempCertScript
Pop-Location
Remove-Item $tempCertScript -Force -ErrorAction SilentlyContinue

# Run init with automated input:
#   - IP: default (empty -> 127.0.0.1)
#   - Port: default (empty -> 5000)
#   - Enable HTTPS: n
#   - Enable registry signing: n
#   - Enable signature validation: n
#   - Enable agent approval: n
#   - Storage mode: file
Write-Host "[INIT] Running registry-center initialization..."
# PowerShell does not support '<' stdin redirection, so use cmd.exe to wrap it.
# Write input to a temp file to avoid PowerShell pipe encoding issues.
$initInputFile = Join-Path $env:TEMP "openan_init_input.txt"
@("", "", "n", "n", "n", "n", "file") -join "`r`n" | Out-File -FilePath $initInputFile -Encoding ASCII -NoNewline
Push-Location $REGISTRY_DIR
Invoke-NativeCommand { cmd.exe /c """$REG_VENV_PYTHON"" -m agent_registry.init < ""$initInputFile""" } "agent_registry.init"
Pop-Location
Remove-Item $initInputFile -Force -ErrorAction SilentlyContinue

Write-Host "[DONE] registry-center initialized."

# =============================================================================
# Step 3: Setup orchestration-center
# =============================================================================
Write-Host ""
Write-Host "=========================================="
Write-Host " Step 3: Setting up orchestration-center"
Write-Host "=========================================="

$OC_VENV_PYTHON = Join-Path $ORCHESTRATION_DIR "venv\Scripts\python.exe"

# Create venv
if (-not (Test-Path $OC_VENV_PYTHON)) {
    Write-Host "[VENV] Creating virtual environment..."
    $pyCmd = Find-PythonCommand
    Write-Host "  [VENV] Running: $($pyCmd.Exe) $($pyCmd.Args -join ' ') -m venv venv"
    Push-Location $ORCHESTRATION_DIR
    Invoke-NativeCommand { & $pyCmd.Exe @($pyCmd.Args + @("-m", "venv", "venv")) } "venv creation (orchestration-center)"
    Pop-Location
    if (-not (Test-Path $OC_VENV_PYTHON)) {
        throw "venv creation finished but $OC_VENV_PYTHON was not found."
    }
} else {
    Write-Host "[SKIP] venv already exists."
}

# Install backend dependencies
Write-Host "[PIP] Installing orchestration-center backend dependencies..."
Invoke-NativeCommand { & $OC_VENV_PYTHON -m pip install --upgrade pip } "pip upgrade (orchestration-center)"
$reqFile = Join-Path $ORCHESTRATION_DIR "requirements.txt"
if (Test-Path $reqFile) {
    Invoke-NativeCommand { & $OC_VENV_PYTHON -m pip install -r $reqFile } "pip install requirements (orchestration-center)"
}

# Install frontend dependencies
Write-Host "[NPM] Installing orchestration-center frontend dependencies..."
$frontendSrcDir = Join-Path $ORCHESTRATION_DIR "workflow-designer"
if (-not (Test-Path $frontendSrcDir)) {
    throw "workflow-designer directory not found: $frontendSrcDir"
}
Push-Location $frontendSrcDir
Invoke-NativeCommand { npm install --force } "npm install"
Pop-Location

# =============================================================================
# Step 4: Start all services
# =============================================================================
Write-Host ""
Write-Host "=========================================="
Write-Host " Step 4: Starting all services"
Write-Host "=========================================="

# Start registry-center (port 5000)
Free-Port -Port 5000
Write-Host "[START] registry-center (http://127.0.0.1:5000)..."
$regLog = Join-Path $REGISTRY_DIR "registry-center.log"
$regErr = Join-Path $REGISTRY_DIR "registry-center-error.log"
$regProc = Start-Process -FilePath $REG_VENV_PYTHON `
    -ArgumentList "-m", "agent_registry.start" `
    -WorkingDirectory $REGISTRY_DIR `
    -WindowStyle Hidden `
    -RedirectStandardOutput $regLog `
    -RedirectStandardError $regErr `
    -PassThru
$REGISTRY_PID = $regProc.Id
Write-Host "  PID: $REGISTRY_PID"

# Start orchestration-center backend (port 5001)
Free-Port -Port 5001
Write-Host "[START] orchestration-center backend (http://127.0.0.1:5001)..."
$backendLog = Join-Path $ORCHESTRATION_DIR "backend.log"
$backendErr = Join-Path $ORCHESTRATION_DIR "backend-error.log"
$ocProc = Start-Process -FilePath $OC_VENV_PYTHON `
    -ArgumentList "-m", "orchestrate.start" `
    -WorkingDirectory $ORCHESTRATION_DIR `
    -WindowStyle Hidden `
    -RedirectStandardOutput $backendLog `
    -RedirectStandardError $backendErr `
    -PassThru
$OC_BACKEND_PID = $ocProc.Id
Write-Host "  PID: $OC_BACKEND_PID"

# Start orchestration-center frontend (port 3003)
Free-Port -Port $FRONTEND_PORT
Write-Host "[START] orchestration-center frontend (http://localhost:$FRONTEND_PORT)..."

$frontendLog = Join-Path $ORCHESTRATION_DIR "frontend.log"
$frontendErr = Join-Path $ORCHESTRATION_DIR "frontend-error.log"
$frontendDir = Join-Path $ORCHESTRATION_DIR "workflow-designer"
$feProc = Start-Process -FilePath "cmd.exe" `
    -ArgumentList "/c npm run dev" `
    -WorkingDirectory $frontendDir `
    -WindowStyle Hidden `
    -RedirectStandardOutput $frontendLog `
    -RedirectStandardError $frontendErr `
    -PassThru
$OC_FRONTEND_PID = $feProc.Id
Write-Host "  PID: $OC_FRONTEND_PID"

# Wait and verify the frontend is actually listening
$FRONTEND_OK = $false
$FRONTEND_REAL_PID = ""
Write-Host "  [WAIT] Verifying frontend startup..."
for ($i = 1; $i -le 20; $i++) {
    $feProcCheck = Get-Process -Id $OC_FRONTEND_PID -ErrorAction SilentlyContinue
    if (-not $feProcCheck) {
        Write-Host "  [ERROR] Frontend process exited unexpectedly."
        Write-Host "          Check log: $frontendLog"
        break
    }
    # Capture the PID that actually owns the port (npm spawns a node child)
    $listening = Get-NetTCPConnection -LocalPort $FRONTEND_PORT -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($listening) {
        $FRONTEND_REAL_PID = "$($listening.OwningProcess)"
        Write-Host "  [OK] Frontend is listening on port $FRONTEND_PORT (PID: $FRONTEND_REAL_PID)"
        $FRONTEND_OK = $true
        break
    }
    Start-Sleep -Seconds 1
}
if (-not $FRONTEND_OK) {
    Write-Host "  [WARN] Frontend may not have started. Check $frontendLog"
    $FRONTEND_REAL_PID = "$OC_FRONTEND_PID"
}

# Start agents examples server (provides sample agents for testing)
$AGENTS_PORT = 8080
Free-Port -Port $AGENTS_PORT
Write-Host "[START] agents examples server (http://127.0.0.1:$AGENTS_PORT)..."
$agentsLog = Join-Path $ORCHESTRATION_DIR "agents-server.log"
$agentsErr = Join-Path $ORCHESTRATION_DIR "agents-server-error.log"
$agentsProc = Start-Process -FilePath $OC_VENV_PYTHON `
    -ArgumentList "-m", "samples.start_agents_server" `
    -WorkingDirectory $ORCHESTRATION_DIR `
    -WindowStyle Hidden `
    -RedirectStandardOutput $agentsLog `
    -RedirectStandardError $agentsErr `
    -PassThru
$AGENTS_PID = $agentsProc.Id
Write-Host "  PID: $AGENTS_PID"

# =============================================================================
# Summary
# =============================================================================
Write-Host ""
Write-Host "=========================================="
Write-Host " All services started!"
Write-Host "=========================================="
Write-Host " registry-center:        http://127.0.0.1:5000  (PID: $REGISTRY_PID)"
Write-Host " orchestration backend:  http://127.0.0.1:5001  (PID: $OC_BACKEND_PID)"
Write-Host " orchestration frontend: http://localhost:$FRONTEND_PORT   (PID: $FRONTEND_REAL_PID)"
Write-Host " agents examples server: http://127.0.0.1:$AGENTS_PORT  (PID: $AGENTS_PID)"
Write-Host ""
Write-Host " Logs:"
Write-Host "   $regLog"
Write-Host "   $backendLog"
Write-Host "   $frontendLog"
Write-Host "   $agentsLog"
Write-Host ""
Write-Host " To stop all: Stop-Process -Id $REGISTRY_PID,$OC_BACKEND_PID,$FRONTEND_REAL_PID,$AGENTS_PID -Force"
Write-Host "=========================================="
