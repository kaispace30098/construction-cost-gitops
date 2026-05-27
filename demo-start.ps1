# =============================================================================
# demo-start.ps1  —  Clean interview demo launcher
# Repo: construction-cost-gitops
# Usage: .\demo-start.ps1
# =============================================================================

$CLUSTER_NAME   = "mlops"
$ARGOCD_NS      = "argocd"
$MODEL_NS       = "mlops"
$MODEL_SVC      = "construction-cost-model"
$GITOPS_REPO    = "https://github.com/kaispace30098/construction-cost-gitops.git"
$KIND_CONFIG     = "$PSScriptRoot\kind-config.yaml"
$ARGOCD_APP     = "$PSScriptRoot\argocd-app.yaml"

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    [OK] $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "    [!!] $msg" -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host "    [ERROR] $msg" -ForegroundColor Red }

# -----------------------------------------------------------------------------
# STEP 1 — Docker Desktop running?
# -----------------------------------------------------------------------------
Write-Step "Checking Docker Desktop..."
$dockerOk = docker info 2>$null
if (-not $?) {
    Write-Err "Docker Desktop is not running. Start it and re-run this script."
    exit 1
}
Write-Ok "Docker is running."

# -----------------------------------------------------------------------------
# STEP 2 — Kind cluster exists?
# -----------------------------------------------------------------------------
Write-Step "Checking kind cluster '$CLUSTER_NAME'..."
$clusters = kind get clusters 2>$null
if ($clusters -notcontains $CLUSTER_NAME) {
    Write-Warn "Cluster '$CLUSTER_NAME' not found. Bootstrapping from scratch..."

    # Create cluster
    Write-Step "Creating kind cluster..."
    kind create cluster --name $CLUSTER_NAME --config $KIND_CONFIG
    if (-not $?) { Write-Err "kind create cluster failed."; exit 1 }

    # Install ArgoCD
    Write-Step "Installing ArgoCD..."
    kubectl create namespace $ARGOCD_NS
    kubectl apply -n $ARGOCD_NS -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
    Write-Ok "Waiting for ArgoCD to be ready (this takes ~60s)..."
    kubectl wait --for=condition=available deployment/argocd-server -n $ARGOCD_NS --timeout=120s

    # Apply ArgoCD app (creates mlops namespace + deploys model)
    Write-Step "Applying ArgoCD application..."
    kubectl apply -f $ARGOCD_APP
    Write-Ok "ArgoCD app applied. ArgoCD will pull and deploy the model image now."

} else {
    Write-Ok "Cluster '$CLUSTER_NAME' exists."
}

# Set kubectl context
kubectl config use-context "kind-$CLUSTER_NAME" | Out-Null

# -----------------------------------------------------------------------------
# STEP 3 — Kill existing port-forwards
# -----------------------------------------------------------------------------
Write-Step "Killing existing kubectl port-forwards..."
Get-Process -Name kubectl -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 1
Write-Ok "Port-forwards cleared."

# -----------------------------------------------------------------------------
# STEP 4 — Wait for model pod READY 1/1
# -----------------------------------------------------------------------------
Write-Step "Waiting for model pod to be READY 1/1..."
$timeout = 120
$elapsed = 0
$ready   = $false

while ($elapsed -lt $timeout) {
    $podStatus = kubectl get pods -n $MODEL_NS --no-headers 2>$null |
                 Where-Object { $_ -match $MODEL_SVC }
    if ($podStatus -match "1/1\s+Running") {
        $ready = $true
        break
    }
    Write-Host "    ... $podStatus" -ForegroundColor DarkGray
    Start-Sleep -Seconds 5
    $elapsed += 5
}

if (-not $ready) {
    Write-Warn "Pod not ready after ${timeout}s. Current state:"
    kubectl get pods -n $MODEL_NS
    Write-Warn "Try: kubectl rollout restart deployment/$MODEL_SVC -n $MODEL_NS"
    exit 1
}
Write-Ok "Pod is READY 1/1."
kubectl get pods -n $MODEL_NS

# -----------------------------------------------------------------------------
# STEP 5 — Start port-forwards in new windows
# -----------------------------------------------------------------------------
Write-Step "Starting port-forwards in new windows..."

# ArgoCD UI  →  https://localhost:8080
Start-Process powershell -ArgumentList "-NoExit", "-Command",
    "Write-Host 'ArgoCD port-forward — https://localhost:8080' -ForegroundColor Cyan; kubectl port-forward svc/argocd-server -n argocd 8080:443"

# Model serving  →  http://localhost:9090
Start-Process powershell -ArgumentList "-NoExit", "-Command",
    "Write-Host 'Model port-forward — http://localhost:9090' -ForegroundColor Cyan; kubectl port-forward svc/$MODEL_SVC -n $MODEL_NS 9090:8080"

Start-Sleep -Seconds 3   # give port-forwards time to bind
Write-Ok "Port-forwards started."

# -----------------------------------------------------------------------------
# STEP 6 — Run demo predictions
# -----------------------------------------------------------------------------
Write-Step "Running demo predictions..."

Write-Host "`n  [HIGH complexity] 45-day, high-risk, heavy constraints:" -ForegroundColor Yellow
$bodyHigh = '{"Task_Duration_Days":45,"Labor_Required":15,"Equipment_Units":8,"Start_Constraint":3,"Risk_Level":"High","Resource_Constraint_Score":6,"Site_Constraint_Score":7,"Dependency_Count":4}'
$high = Invoke-RestMethod -Uri http://localhost:9090/predict -Method Post -ContentType "application/json" -Body $bodyHigh
Write-Host ("  Predicted cost: `$" + ("{0:N2}" -f $high.predicted_cost_usd)) -ForegroundColor Green

Write-Host "`n  [LOW complexity] 5-day, low-risk, no constraints:" -ForegroundColor Yellow
$bodyLow = '{"Task_Duration_Days":5,"Labor_Required":2,"Equipment_Units":1,"Start_Constraint":0,"Risk_Level":"Low","Resource_Constraint_Score":1,"Site_Constraint_Score":1,"Dependency_Count":0}'
$low = Invoke-RestMethod -Uri http://localhost:9090/predict -Method Post -ContentType "application/json" -Body $bodyLow
Write-Host ("  Predicted cost: `$" + ("{0:N2}" -f $low.predicted_cost_usd)) -ForegroundColor Green

$ratio = [math]::Round($high.predicted_cost_usd / $low.predicted_cost_usd, 1)
Write-Host "`n  Model prices complexity correctly: high/low ratio = ${ratio}x" -ForegroundColor Cyan

# -----------------------------------------------------------------------------
# DONE
# -----------------------------------------------------------------------------
Write-Host @"

=============================================================================
  DEMO READY
=============================================================================
  ArgoCD UI  : https://localhost:8080  (accept cert warning)
               Login: admin / run the command below to get password
               kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" | %{ [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(`$_)) }

  Predictions: http://localhost:9090/predict
=============================================================================
"@ -ForegroundColor Cyan
