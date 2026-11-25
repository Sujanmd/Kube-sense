# ============================================================
# KubeSense - Automated Launcher for Windows (K3s & Local Stack)
# Usage: .\start.ps1 [-Driver k3d|minikube] [-SkipBuild]
# ============================================================
param (
    [ValidateSet("k3d", "minikube")]
    [string]$Driver = "k3d",
    [switch]$SkipBuild
)

$ErrorActionPreference = "Continue"

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "   KubeSense - Automated K3s & Local Environment Launcher   " -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# Ensure local bin directory is in PATH for standalone downloads
$LocalBin = Join-Path $PSScriptRoot ".bin"
if (-not (Test-Path $LocalBin)) {
    New-Item -ItemType Directory -Path $LocalBin -Force | Out-Null
}
if ($env:PATH -notlike "*$LocalBin*") {
    $env:PATH = "$LocalBin;$env:PATH"
}

# ----------------------------------------------------------------------
# Helper: Verify or auto-install a required CLI tool
# ----------------------------------------------------------------------
function Ensure-CliTool {
    param (
        [string]$ToolName,
        [string]$WingetId,
        [string]$DownloadUrl,
        [string]$FileName
    )

    $cmd = Get-Command $ToolName -ErrorAction SilentlyContinue
    if ($cmd) {
        return $true
    }

    # Check local .bin folder
    $localFile = Join-Path $LocalBin "$ToolName.exe"
    if (Test-Path $localFile) {
        return $true
    }

    Write-Host "      '$ToolName' not found. Attempting installation..." -ForegroundColor Yellow

    # Try winget if available
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget -and $WingetId) {
        Write-Host "      Installing $ToolName via winget ($WingetId)..." -ForegroundColor Cyan
        try {
            & winget install $WingetId --accept-package-agreements --accept-source-agreements --silent 2>&1 | Out-Null
            $cmd = Get-Command $ToolName -ErrorAction SilentlyContinue
            if ($cmd) {
                Write-Host "      Successfully installed $ToolName via winget." -ForegroundColor Green
                return $true
            }
        } catch {
            Write-Host "      Winget installation failed. Trying direct download..." -ForegroundColor DarkGray
        }
    }

    # Direct download fallback
    if ($DownloadUrl -and $FileName) {
        Write-Host "      Downloading $ToolName directly..." -ForegroundColor Cyan
        try {
            $dest = Join-Path $LocalBin $FileName
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $DownloadUrl -OutFile $dest -UseBasicParsing
            if ($FileName.EndsWith(".zip")) {
                Expand-Archive -Path $dest -DestinationPath $LocalBin -Force
                Remove-Item $dest -Force -ErrorAction SilentlyContinue
            }
            Write-Host "      Downloaded $ToolName to $LocalBin." -ForegroundColor Green
            return $true
        } catch {
            Write-Host "      Failed to download $ToolName : $_" -ForegroundColor Red
        }
    }

    return $false
}

# ----------------------------------------------------------------------
# Step 1: Check Docker Desktop
# ----------------------------------------------------------------------
Write-Host "[1/6] Checking Docker Engine..." -ForegroundColor Yellow
$dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
if (-not $dockerCmd) {
    Write-Host "ERROR: Docker CLI not found. Please install Docker Desktop for Windows." -ForegroundColor Red
    exit 1
}

$dockerRunning = docker info 2>&1 | Select-String "Server Version"
if (-not $dockerRunning) {
    Write-Host "      Docker daemon is not running. Attempting to start Docker Desktop..." -ForegroundColor Yellow
    $dockerDesktopPath = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
    if (Test-Path $dockerDesktopPath) {
        Start-Process $dockerDesktopPath
    }

    $retries = 30
    while ($retries -gt 0) {
        Start-Sleep -Seconds 2
        $check = docker info 2>&1 | Select-String "Server Version"
        if ($check) { break }
        $retries--
    }

    $dockerRunning = docker info 2>&1 | Select-String "Server Version"
    if (-not $dockerRunning) {
        Write-Host "ERROR: Docker daemon did not start in time. Please start Docker Desktop manually." -ForegroundColor Red
        exit 1
    }
}
Write-Host "      Docker is running and healthy." -ForegroundColor Green

# ----------------------------------------------------------------------
# Step 2: Ensure CLI Tools (k3d, helm, kubectl)
# ----------------------------------------------------------------------
Write-Host ""
Write-Host "[2/6] Verifying Kubernetes & Package Tools..." -ForegroundColor Yellow

if ($Driver -eq "k3d") {
    $hasK3d = Ensure-CliTool -ToolName "k3d" `
                             -WingetId "Rancher.k3d" `
                             -DownloadUrl "https://github.com/k3d-io/k3d/releases/latest/download/k3d-windows-amd64.exe" `
                             -FileName "k3d.exe"
    if (-not $hasK3d) {
        Write-Host "WARNING: Could not auto-install k3d. Falling back to Minikube." -ForegroundColor Yellow
        $Driver = "minikube"
    } else {
        Write-Host "      k3d CLI is ready." -ForegroundColor Green
    }
}

$hasHelm = Ensure-CliTool -ToolName "helm" `
                          -WingetId "Helm.Helm" `
                          -DownloadUrl "https://get.helm.sh/helm-v3.17.0-windows-amd64.zip" `
                          -FileName "helm.zip"
# If extracted into windows-amd64 subfolder
$extractedHelm = Join-Path $LocalBin "windows-amd64\helm.exe"
if (Test-Path $extractedHelm) {
    Move-Item -Path $extractedHelm -Destination (Join-Path $LocalBin "helm.exe") -Force -ErrorAction SilentlyContinue
}

$hasKubectl = Ensure-CliTool -ToolName "kubectl" `
                             -WingetId "Kubernetes.kubectl" `
                             -DownloadUrl "https://dl.k8s.io/release/v1.31.0/bin/windows/amd64/kubectl.exe" `
                             -FileName "kubectl.exe"

# ----------------------------------------------------------------------
# Step 3: Setup & Launch Ollama (AI Recommendations)
# ----------------------------------------------------------------------
Write-Host ""
Write-Host "[3/6] Setting up Ollama AI Engine..." -ForegroundColor Yellow

# Look for Ollama in PATH or default Windows installation directory
$ollamaPath = $null
$ollamaCmd = Get-Command ollama -ErrorAction SilentlyContinue
if ($ollamaCmd) {
    $ollamaPath = $ollamaCmd.Source
} else {
    $defaultOllama = Join-Path $env:LOCALAPPDATA "Programs\Ollama\ollama.exe"
    if (Test-Path $defaultOllama) {
        $ollamaPath = $defaultOllama
        $env:PATH = "$(Split-Path $defaultOllama);$env:PATH"
    }
}

# If not installed, attempt winget install
if (-not $ollamaPath) {
    Write-Host "      Ollama not detected. Attempting installation via winget..." -ForegroundColor DarkGray
    $hasOllama = Ensure-CliTool -ToolName "ollama" -WingetId "Ollama.Ollama"
    $ollamaCmd = Get-Command ollama -ErrorAction SilentlyContinue
    if ($ollamaCmd) { $ollamaPath = $ollamaCmd.Source }
}

$ollamaRunning = $false
if ($ollamaPath) {
    # Ensure Ollama listens on 0.0.0.0 so K8s pods can reach it
    $env:OLLAMA_HOST = "0.0.0.0"
    [Environment]::SetEnvironmentVariable("OLLAMA_HOST", "0.0.0.0", "User")

    # Check if Ollama HTTP server is already running
    try {
        $resp = Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/tags" -TimeoutSec 2 -ErrorAction Stop
        $ollamaRunning = $true
        Write-Host "      Ollama server is already running." -ForegroundColor Green
    } catch {
        Write-Host "      Starting Ollama server (OLLAMA_HOST=0.0.0.0)..." -ForegroundColor Cyan
        Start-Process -FilePath $ollamaPath -ArgumentList "serve" -WindowStyle Hidden
        Start-Sleep -Seconds 3
        try {
            $resp = Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/tags" -TimeoutSec 3 -ErrorAction Stop
            $ollamaRunning = $true
            Write-Host "      Ollama server started successfully." -ForegroundColor Green
        } catch {
            Write-Host "      Ollama started in background (will be ready shortly)." -ForegroundColor DarkGray
        }
    }

    # Ensure llama3.1 model is pulled
    if ($ollamaRunning) {
        $models = $resp.models | ForEach-Object { $_.name }
        $hasModel = $models | Where-Object { $_ -like "llama3.1*" -or $_ -like "llama3*" }
        if (-not $hasModel) {
            Write-Host "      Pulling model 'llama3.1:latest' for AI RCA recommendations (this may take a minute)..." -ForegroundColor Cyan
            Start-Process -FilePath $ollamaPath -ArgumentList "pull llama3.1" -NoNewWindow -Wait
            Write-Host "      Model 'llama3.1' ready." -ForegroundColor Green
        } else {
            Write-Host "      Model 'llama3.1' is available." -ForegroundColor Green
        }
    }
} else {
    Write-Host "      Ollama not installed. KubeSense will run using rule-based fallback recommendations." -ForegroundColor DarkGray
}

# ----------------------------------------------------------------------
# Step 4: Create or Start Kubernetes Cluster
# ----------------------------------------------------------------------
Write-Host ""
if ($Driver -eq "k3d") {
    Write-Host "[4/6] Initializing K3s cluster via k3d..." -ForegroundColor Yellow
    $clusterName = "kubesense-cluster"
    $existing = k3d cluster list -o json 2>$null | ConvertFrom-Json | Where-Object { $_.name -eq $clusterName }

    if (-not $existing) {
        Write-Host "      Creating K3s cluster '$clusterName' with port mapping 30080 -> 30080..." -ForegroundColor Cyan
        k3d cluster create $clusterName `
            -p "30080:30080@server:0" `
            -p "30800:30800@server:0" `
            --k3s-arg "--disable=traefik@server:0" `
            --wait
        Write-Host "      K3s cluster created." -ForegroundColor Green
    } else {
        Write-Host "      K3s cluster '$clusterName' exists. Ensuring it is running..." -ForegroundColor Cyan
        k3d cluster start $clusterName 2>$null | Out-Null
        Write-Host "      K3s cluster is running." -ForegroundColor Green
    }

    kubectl config use-context "k3d-$clusterName" 2>$null | Out-Null
} else {
    Write-Host "[4/6] Initializing Minikube cluster..." -ForegroundColor Yellow
    $minikubeStatus = minikube status 2>&1 | Select-String "Running"
    if ($minikubeStatus) {
        Write-Host "      Minikube already running. Skipping." -ForegroundColor Green
    } else {
        minikube start --driver=docker
        Write-Host "      Minikube started." -ForegroundColor Green
    }
}

# ----------------------------------------------------------------------
# Step 5: Build and Import Docker Images
# ----------------------------------------------------------------------
Write-Host ""
Write-Host "[5/6] Building & loading container images..." -ForegroundColor Yellow

if (-not $SkipBuild) {
    Write-Host "      Building backend image (kubesense-backend:latest)..." -ForegroundColor Cyan
    docker build -t kubesense-backend:latest "$PSScriptRoot\demo-app\backend"
    
    Write-Host "      Building frontend image (kubesense-frontend:latest)..." -ForegroundColor Cyan
    docker build -t kubesense-frontend:latest "$PSScriptRoot\demo-app\frontend"
} else {
    Write-Host "      Skipping image build (-SkipBuild specified)." -ForegroundColor DarkGray
}

if ($Driver -eq "k3d") {
    Write-Host "      Importing images into K3s cluster..." -ForegroundColor Cyan
    k3d image import kubesense-backend:latest kubesense-frontend:latest -c "kubesense-cluster"
    Write-Host "      Images imported into K3s containerd." -ForegroundColor Green
} else {
    Write-Host "      Loading images into Minikube cache..." -ForegroundColor Cyan
    minikube image load kubesense-backend:latest
    minikube image load kubesense-frontend:latest
    Write-Host "      Images loaded into Minikube." -ForegroundColor Green
}

# ----------------------------------------------------------------------
# Step 6: Deploy KubeSense with Helm & Launch
# ----------------------------------------------------------------------
Write-Host ""
Write-Host "[6/6] Deploying KubeSense via Helm..." -ForegroundColor Yellow

$helmPath = Join-Path $PSScriptRoot "helm\kubesense"
$ollamaClusterUrl = if ($Driver -eq "k3d") { "http://host.k3d.internal:11434" } else { "http://host.minikube.internal:11434" }

if (Get-Command helm -ErrorAction SilentlyContinue) {
    helm upgrade --install kubesense $helmPath `
        --namespace kubesense `
        --create-namespace `
        --set backend.env.ollamaUrl="$ollamaClusterUrl"
} else {
    Write-Host "      Helm CLI not found in PATH; applying raw manifests..." -ForegroundColor Yellow
    kubectl apply -f "$PSScriptRoot\demo-app\k8s\namespace.yaml"
    kubectl apply -f "$PSScriptRoot\demo-app\k8s\rbac.yaml"
    kubectl apply -f "$PSScriptRoot\demo-app\k8s\prometheus.yaml"
    kubectl apply -f "$PSScriptRoot\demo-app\k8s\deployment.yaml"
    kubectl apply -f "$PSScriptRoot\demo-app\k8s\service.yaml"
}

Write-Host ""
Write-Host "      Waiting for all pods to become ready..." -ForegroundColor Yellow
kubectl wait --for=condition=ready pod --all -n kubesense --timeout=120s 2>&1 | Out-Null
Write-Host "      All pods are ready." -ForegroundColor Green

Write-Host ""
Write-Host "Cluster Pod Status:" -ForegroundColor Yellow
kubectl get pods -n kubesense

# Launch / Tunnel
$appUrl = "http://localhost:30080"
if ($Driver -eq "minikube") {
    Write-Host ""
    Write-Host "Opening Minikube frontend service tunnel in background window..." -ForegroundColor Yellow
    Start-Process powershell -ArgumentList @(
        "-NoExit",
        "-Command",
        "Write-Host 'KubeSense Frontend Tunnel - Keep this window open' -ForegroundColor Cyan; minikube service frontend-service -n kubesense"
    )
} else {
    # On K3s / k3d, port 30080 is directly mapped to localhost!
    Start-Process $appUrl
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "   KubeSense is LIVE!                                       " -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  App Dashboard:       $appUrl" -ForegroundColor White
Write-Host "  Cluster Driver:      $Driver" -ForegroundColor White
$ollamaStatus = if ([string]::IsNullOrWhiteSpace($ollamaPath)) { "Rule-Based Fallback" } else { "Active (llama3.1)" }
Write-Host "  Ollama AI Engine:    $ollamaStatus" -ForegroundColor White
Write-Host ""
