
# construction-cost-gitops
<img width="2542" height="828" alt="image" src="https://github.com/user-attachments/assets/344666be-8121-4eb6-bb53-31039774d703" />
<img width="2360" height="1412" alt="image" src="https://github.com/user-attachments/assets/5c677286-f37a-48d2-8f84-716374facea6" />


GitOps manifest repo for construction-cost-model.
ArgoCD watches this repo and syncs to the kind cluster automatically.

---

## Structure

```
construction-cost-gitops/
|-- deployment.yaml      # image tag updated by CI on every successful train
|-- service.yaml         # ClusterIP, exposes port 8080 inside cluster
|-- kustomization.yaml   # kustomize entrypoint
|-- kind-config.yaml     # kind cluster definition (1 control-plane + 2 workers)
|-- argocd-app.yaml      # ArgoCD Application manifest
|-- demo-start.ps1       # one-shot interview demo launcher
\-- README.md
```

---

## How it works

```
Repo 1 CI (construction-cost-model) finishes package job
  -> updates image SHA in deployment.yaml
  -> git push here

ArgoCD polls this repo every ~3 min
  -> detects deployment.yaml changed
  -> pulls new image from ghcr.io
  -> rolling update in kind cluster (zero manual steps)
```

---

## Demo launcher

```powershell
.\demo-start.ps1
```

Handles everything automatically:
- Checks Docker Desktop is running
- Checks kind cluster exists (bootstraps from scratch if deleted)
- Kills stale port-forwards
- Waits for model pod READY 1/1
- Starts port-forwards in new windows
- Waits until port 9090 is accepting connections
- Fires both demo predictions
- Decodes ArgoCD password and opens both browser tabs

---

## Ports

| Port | What | Command |
|------|------|---------|
| 8080 | ArgoCD UI (HTTPS) | `kubectl port-forward svc/argocd-server -n argocd 8080:443` |
| 9090 | Model prediction API | `kubectl port-forward svc/construction-cost-model -n mlops 9090:8080` |

> Note: 8080 is used for ArgoCD. Use 9090 for the model — not 8080.

---

## URLs

| URL | Description |
|-----|-------------|
| `https://localhost:8080` | ArgoCD UI (accept cert warning) |
| `http://localhost:9090/docs` | FastAPI Swagger UI — try /predict interactively |
| `http://localhost:9090/health` | Health check |
| `http://localhost:9090/predict` | Prediction endpoint (POST) |

---

## ArgoCD login

Username: `admin`

Get password (stays the same until cluster is deleted):
```powershell
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" | ForEach-Object { [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_)) }
```

---

## Manual prediction (without demo script)

```powershell
# High complexity -> ~$52,706
Invoke-RestMethod -Uri http://localhost:9090/predict -Method Post -ContentType "application/json" -Body (
    [PSCustomObject]@{
        Task_Duration_Days=45; Labor_Required=15; Equipment_Units=8
        Start_Constraint=3; Risk_Level="High"
        Resource_Constraint_Score=6; Site_Constraint_Score=7; Dependency_Count=4
    } | ConvertTo-Json -Compress
)

# Low complexity -> ~$16,854
Invoke-RestMethod -Uri http://localhost:9090/predict -Method Post -ContentType "application/json" -Body (
    [PSCustomObject]@{
        Task_Duration_Days=5; Labor_Required=2; Equipment_Units=1
        Start_Constraint=0; Risk_Level="Low"
        Resource_Constraint_Score=1; Site_Constraint_Score=1; Dependency_Count=0
    } | ConvertTo-Json -Compress
)
```

---

## Bootstrap from scratch (if kind cluster deleted)

`demo-start.ps1` handles this automatically. Manual steps if needed:

```powershell
# 1. Create cluster
kind create cluster --name mlops --config kind-config.yaml

# 2. Install ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=120s

# 3. Apply ArgoCD app (creates mlops namespace + deploys model)
kubectl apply -f argocd-app.yaml

# 4. Run demo
.\demo-start.ps1
```
