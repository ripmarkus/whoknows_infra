# GitOps Pipeline Implementation Guide

## Overview

This guide walks you through building a complete GitOps pipeline for your Kubernetes infrastructure on Hetzner Cloud. The pipeline spans five stages: infrastructure provisioning, cluster bootstrap, Kubernetes component installation, app deployment, and full CI/CD automation.

**Current Status:** Terraform CI/CD is complete. Everything after infrastructure provisioning is manual or missing.

---

## Stage 1: Infrastructure Provisioning (Terraform) ✅

**Status:** Complete

### What's in place
- `.github/workflows/terraform.yml` — automated plan on PR, gated apply on merge to `main`
- Terraform Cloud remote state backend
- Hetzner Cloud resources:
  - VPC: `10.0.0.0/16`
  - Subnet: `10.0.0.0/24`
  - NAT VM (Debian 12, public IP for SSH access)
  - 2 control plane nodes (Talos Linux, private IPs)
  - 1 worker node (Talos Linux, private IP)
  - Load balancer (public IP) with services for Talos API (port 50000) and Kubernetes API (port 6443)

### What you need to do
Nothing. This stage is complete and requires no changes.

---

## Stage 2: Cluster Bootstrap (Manual, One-Time)

**Status:** Not started

This stage cannot be automated in CI because it requires direct access to the Talos API before Kubernetes exists. Run these steps locally after `terraform apply` completes. You only do this once per cluster.

### Prerequisites
- `talosctl` installed locally
- `kubectl` installed locally
- SSH access to the NAT VM or a way to reach node private IPs

### Step-by-step

#### 1. Get infrastructure outputs
```bash
cd terraform
LB_IP=$(terraform output -raw load_balancer_ip)
NAT_IP=$(terraform output -raw nat_vm_ip)
echo "Load Balancer IP: $LB_IP"
echo "NAT VM IP: $NAT_IP"
```

#### 2. Update the hardcoded LB IP in Talos patch

Open `talos/patches/patch-cp.yaml` and update the `certSANs` field:
```yaml
machine:
  certSANs:
    - $LB_IP  # Replace with actual IP from step 1
```

This IP must match the load balancer public IP, or Talos bootstrap will fail.

#### 3. Generate Talos secrets and machine configs

Create the `talos/generated/` directory (it's gitignored):
```bash
mkdir -p talos/generated
cd talos/generated

# Generate secrets (reuse if you have them, or generate fresh)
talosctl gen secrets -o secrets.yaml

# Generate machine configs
talosctl gen config whoknows https://$LB_IP:6443 \
  --with-secrets ./secrets.yaml \
  --config-patch-control-plane @../patches/patch-cp.yaml \
  --config-patch @../patches/patch.yaml \
  --output ./

cd ../..
```

Output files (all gitignored):
- `talos/generated/secrets.yaml`
- `talos/generated/controlplane.yaml`
- `talos/generated/worker.yaml`
- `talos/generated/talosconfig`

#### 4. Apply Talos configs to nodes

First, determine the private IPs of your nodes by inspecting the Hetzner console or the Terraform state. Then apply configs:

```bash
# Get node IPs from Terraform state or Hetzner console
# For this example: CP1=10.0.0.3, CP2=10.0.0.4, Worker=10.0.0.5
# You can also derive them from the Terraform output or console

CP1_IP=10.0.0.3
CP2_IP=10.0.0.4
WORKER_IP=10.0.0.5
TALOS_CONFIG=$(pwd)/talos/generated/talosconfig

# Apply control plane config to first node
talosctl apply-config \
  --insecure \
  --nodes $CP1_IP \
  --file talos/generated/controlplane.yaml \
  --talosconfig $TALOS_CONFIG

# Apply control plane config to second node
talosctl apply-config \
  --insecure \
  --nodes $CP2_IP \
  --file talos/generated/controlplane.yaml \
  --talosconfig $TALOS_CONFIG

# Apply worker config to worker node
talosctl apply-config \
  --insecure \
  --nodes $WORKER_IP \
  --file talos/generated/worker.yaml \
  --talosconfig $TALOS_CONFIG
```

**Note:** If nodes are not directly reachable, use SSH through the NAT VM:
```bash
talosctl apply-config \
  --insecure \
  --nodes $CP1_IP \
  --file talos/generated/controlplane.yaml \
  --talosconfig $TALOS_CONFIG \
  --proxies $NAT_IP:50000
```

#### 5. Bootstrap etcd

Bootstrap the cluster (run once, on any control plane):
```bash
talosctl bootstrap \
  --nodes $CP1_IP \
  --talosconfig $TALOS_CONFIG
```

Wait 30-60 seconds for etcd to initialize.

#### 6. Generate kubeconfig

```bash
talosctl kubeconfig \
  --nodes $LB_IP \
  --talosconfig $TALOS_CONFIG

# Verify access
kubectl cluster-info
kubectl get nodes
```

All nodes should show as `NotReady` (CNI not installed yet).

#### 7. Save TALOSCONFIG_B64 for CI/CD

The deploy workflow needs the talosconfig encoded as a base64 secret:

```bash
cat talos/generated/talosconfig | base64 -w 0 > talos/talosconfig.b64
cat talos/talosconfig.b64
```

**Add to GitHub Actions secrets** for this repository:
- Secret name: `TALOSCONFIG_B64`
- Value: Output from above command

See [secrets-setup.md](secrets-setup.md) for detailed instructions.

### What to add to the repo

1. **`docs/bootstrap.md`** — Document these steps as a reproduction guide
2. **Update `talos/patches/patch-cp.yaml`** — Remove hardcoded IP, add a comment about how to fill it in
3. **Add GitHub Actions secret `TALOSCONFIG_B64`** — Critical for the deploy workflow

### Verification
```bash
kubectl get nodes
# Should show all 3 nodes in NotReady state (waiting for CNI)
```

---

## Stage 3: Kubernetes Infrastructure Components

**Status:** Partially missing (files exist but incomplete)

Install Kubernetes infrastructure in this order. Each component depends on the previous one.

### 3a. Cilium CNI (Must come first)

**Why:** Pods cannot start without a Container Network Interface. Cilium also provides Gateway API support.

**File exists:** `kubernetes/cilium/values.yaml`

**Verify the values file contains:**
```yaml
gatewayAPI:
  enabled: true
kubeProxyReplacement: true
```

**Install manually:**
```bash
helm repo add cilium https://helm.cilium.io/
helm upgrade --install cilium cilium/cilium \
  --namespace kube-system \
  --values kubernetes/cilium/values.yaml \
  --version 1.16.x
```

**Verify:**
```bash
kubectl get pods -n kube-system | grep cilium
# All cilium pods should be Running
```

### 3b. Hetzner Cloud Controller Manager (HCCM)

**Why:** Provides cloud-aware features: node labels, cloud load balancer integration, automatic node cleanup on VM deletion.

**File status:** `kubernetes/hccm/hccm.yaml` contains only env var snippets — needs a proper Helm values file.

**Create `kubernetes/hccm/values.yaml`:**

First, get your Hetzner network ID:
```bash
cd terraform
terraform output
# Look for any network-related output, or check the Hetzner console
# For now, use a placeholder: HCLOUD_NETWORK_ID
```

```yaml
# kubernetes/hccm/values.yaml
env:
  HCLOUD_NETWORK:
    valueFrom:
      secretKeyRef:
        name: hcloud
        key: network
  HCLOUD_TOKEN:
    valueFrom:
      secretKeyRef:
        name: hcloud
        key: token

networking:
  enabled: false
```

**Create the required secret (run once):**
```bash
# Get your Hetzner token from environment or saved secrets
HCLOUD_TOKEN="<your-token>"
HCLOUD_NETWORK_ID="<network-id-from-terraform>"

kubectl create secret generic hcloud \
  --namespace kube-system \
  --from-literal=token=$HCLOUD_TOKEN \
  --from-literal=network=$HCLOUD_NETWORK_ID
```

**Install manually:**
```bash
helm repo add hcloud https://charts.hetzner.cloud
helm upgrade --install hcloud-cloud-controller-manager hcloud/hcloud-cloud-controller-manager \
  --namespace kube-system \
  --values kubernetes/hccm/values.yaml
```

**Verify:**
```bash
kubectl get pods -n kube-system | grep hcloud
kubectl get nodes -o wide
# Nodes should have cloud provider labels (e.g., topology.kubernetes.io/zone)
```

### 3c. Hetzner CSI Driver

**Why:** Without a Container Storage Interface driver, all PersistentVolumeClaims stay `Pending`. Your `test-app.yaml` declares a PVC but it won't bind.

**Create `kubernetes/csi/values.yaml`:**
```yaml
storageClasses:
  - name: hcloud-volumes
    defaultStorageClass: true
```

**Install manually:**
```bash
helm repo add hcloud-csi https://charts.hetzner.cloud
helm upgrade --install hcloud-csi hcloud/hcloud-csi \
  --namespace kube-system \
  --values kubernetes/csi/values.yaml
```

**Verify:**
```bash
kubectl get storageclass
# hcloud-volumes should exist and be default

# Test PVC binding
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: hcloud-volumes
  resources:
    requests:
      storage: 10Gi
EOF

kubectl get pvc test-pvc
# Should show Bound after ~10 seconds
```

### 3d. Gateway API Resources

**Why:** The Gateway API (via Cilium) provides HTTP routing. Without it, traffic from the load balancer can't reach services.

**Create `kubernetes/gateway/gateway.yaml`:**
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: gateway-system

---

apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: cilium
spec:
  controllerName: io.cilium/gateway-controller

---

apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: main-gateway
  namespace: default
spec:
  gatewayClassName: cilium
  listeners:
    - name: http
      protocol: HTTP
      port: 80
```

**Install the Gateway API CRDs first:**
```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml
```

**Apply the Gateway manifest:**
```bash
kubectl apply -f kubernetes/gateway/gateway.yaml
```

**Verify:**
```bash
kubectl get gateway -o wide
# main-gateway should show an EXTERNAL-IP (the load balancer IP)
```

### 3e. cert-manager + HTTPS

**Why:** TLS certificates for HTTPS. Integrates with Let's Encrypt for automatic certificate management. Listed as TODO in your ROADMAP.

**Create `kubernetes/cert-manager/values.yaml`:**
```yaml
installCRDs: true

global:
  leaderElection:
    namespace: cert-manager
```

**Create `kubernetes/cert-manager/cluster-issuer.yaml`:**
```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: your-email@example.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
      - http01:
          gatewayHTTPRoute: {}
```

**Install manually:**
```bash
helm repo add jetstack https://charts.jetstack.io
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --values kubernetes/cert-manager/values.yaml

# Apply the ClusterIssuer
kubectl apply -f kubernetes/cert-manager/cluster-issuer.yaml
```

**Verify:**
```bash
kubectl get pods -n cert-manager
kubectl get clusterissuer letsencrypt-prod -o wide
# Status should be True
```

### Summary: Files to Create
- `kubernetes/hccm/values.yaml` (replace current snippet)
- `kubernetes/csi/values.yaml` (new)
- `kubernetes/cert-manager/values.yaml` (new)
- `kubernetes/cert-manager/cluster-issuer.yaml` (new)
- `kubernetes/gateway/gateway.yaml` (new)

---

## Stage 4: Application Deployment

**Status:** Test app exists but incomplete

### 4a. Fix the test app

Your `kubernetes/apps/test-app.yaml` has a Deployment and Service, but no HTTPRoute. Add the missing route:

```yaml
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: nginx-route
spec:
  parentRefs:
    - name: main-gateway
  hostnames:
    - "*"
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: nginx-service
          port: 80
```

Append this to `kubernetes/apps/test-app.yaml`.

**Verify:**
```bash
kubectl apply -f kubernetes/apps/test-app.yaml
kubectl get pod -l app=nginx
# Should be Running

kubectl get httproute
# nginx-route should exist

curl http://<load-balancer-ip>
# Should return the nginx page
```

### 4b. Real app manifests (optional for now)

For the real `whoknows_ripmarkus` application, create `kubernetes/apps/whoknows.yaml` with the same pattern:
- `Deployment` — with an image tag that CI will inject
- `Service` — ClusterIP
- `HTTPRoute` — routes traffic from `main-gateway`

The `scripts/deploy.sh` already handles image injection; it just needs a manifest template.

---

## Stage 5: Full CI/CD Automation

**Status:** Not started (critical gap)

This is where the GitOps magic happens. GitHub Actions automatically applies all infrastructure and app manifests on push.

### 5a. Add required GitHub Actions secrets

Navigate to your repository → Settings → Secrets and variables → Actions.

Add:
| Secret | Value |
|--------|-------|
| `TALOSCONFIG_B64` | base64-encoded talosconfig (from Stage 2, step 7) |
| `LOAD_BALANCER_IP` | Public IP of the load balancer (from `terraform output`) |
| `HCLOUD_TOKEN` | Your Hetzner API token (reuse from Terraform) |
| `HCLOUD_NETWORK_ID` | Your Hetzner network ID (from Terraform) |

See [secrets-setup.md](secrets-setup.md) for detailed instructions.

### 5b. Create the deploy workflow

Create `.github/workflows/deploy.yml`:

```yaml
name: Deploy Kubernetes Infrastructure

on:
  push:
    branches:
      - main
    paths:
      - 'kubernetes/**'
      - '.github/workflows/deploy.yml'

permissions:
  contents: read

jobs:
  get-kubeconfig:
    runs-on: ubuntu-latest
    outputs:
      kubeconfig: ${{ steps.kubeconfig.outputs.path }}
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Install talosctl
        run: |
          curl -sL https://github.com/siderolabs/talos/releases/download/v1.7.0/talosctl-linux-amd64 -o talosctl
          chmod +x talosctl
          sudo mv talosctl /usr/local/bin/

      - name: Install kubectl
        uses: azure/setup-kubectl@v3

      - name: Decode TALOSCONFIG
        run: |
          echo "${{ secrets.TALOSCONFIG_B64 }}" | base64 -d > ~/.talos/config
          chmod 600 ~/.talos/config
        env:
          HOME: ${{ runner.temp }}

      - name: Generate kubeconfig
        id: kubeconfig
        run: |
          KUBECONFIG=${{ runner.temp }}/kubeconfig
          talosctl kubeconfig \
            --nodes ${{ secrets.LOAD_BALANCER_IP }} \
            --talosconfig ~/.talos/config \
            --output $KUBECONFIG
          echo "path=$KUBECONFIG" >> $GITHUB_OUTPUT
          chmod 600 $KUBECONFIG
        env:
          HOME: ${{ runner.temp }}

      - name: Verify cluster access
        run: |
          export KUBECONFIG=${{ steps.kubeconfig.outputs.path }}
          kubectl cluster-info
          kubectl get nodes

  deploy-infra:
    needs: get-kubeconfig
    runs-on: ubuntu-latest
    environment: production
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Install kubectl
        uses: azure/setup-kubectl@v3

      - name: Install Helm
        uses: azure/setup-helm@v3
        with:
          version: 'v3.13.0'

      - name: Set kubeconfig
        run: |
          echo "${{ secrets.KUBECONFIG }}" | base64 -d > ~/.kube/config
          chmod 600 ~/.kube/config
        env:
          HOME: ${{ runner.temp }}

      - name: Create hcloud secret
        run: |
          kubectl create secret generic hcloud \
            --namespace kube-system \
            --from-literal=token=${{ secrets.HCLOUD_TOKEN }} \
            --from-literal=network=${{ secrets.HCLOUD_NETWORK_ID }} \
            --dry-run=client -o yaml | kubectl apply -f -

      - name: Install/upgrade Cilium
        run: |
          helm repo add cilium https://helm.cilium.io
          helm repo update
          helm upgrade --install cilium cilium/cilium \
            --namespace kube-system \
            --values kubernetes/cilium/values.yaml \
            --version 1.16.x \
            --wait

      - name: Install/upgrade HCCM
        run: |
          helm repo add hcloud https://charts.hetzner.cloud
          helm repo update
          helm upgrade --install hcloud-cloud-controller-manager hcloud/hcloud-cloud-controller-manager \
            --namespace kube-system \
            --values kubernetes/hccm/values.yaml \
            --wait

      - name: Install/upgrade Hetzner CSI
        run: |
          helm repo add hcloud-csi https://charts.hetzner.cloud
          helm repo update
          helm upgrade --install hcloud-csi hcloud/hcloud-csi \
            --namespace kube-system \
            --values kubernetes/csi/values.yaml \
            --wait

      - name: Apply Gateway resources
        run: |
          kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml
          kubectl apply -f kubernetes/gateway/

      - name: Install/upgrade cert-manager
        run: |
          helm repo add jetstack https://charts.jetstack.io
          helm repo update
          helm upgrade --install cert-manager jetstack/cert-manager \
            --namespace cert-manager \
            --create-namespace \
            --values kubernetes/cert-manager/values.yaml \
            --set installCRDs=true \
            --wait
          kubectl apply -f kubernetes/cert-manager/

  deploy-apps:
    needs: deploy-infra
    runs-on: ubuntu-latest
    environment: production
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Install kubectl
        uses: azure/setup-kubectl@v3

      - name: Set kubeconfig
        run: |
          echo "${{ secrets.KUBECONFIG }}" | base64 -d > ~/.kube/config
          chmod 600 ~/.kube/config
        env:
          HOME: ${{ runner.temp }}

      - name: Deploy apps
        run: |
          kubectl apply -f kubernetes/apps/

      - name: Verify deployments
        run: |
          kubectl rollout status deployment/nginx-deployment -n default --timeout=5m
```

### 5c. Integration with app repo

The app repo (`whoknows_ripmarkus`) triggers app-specific deployments. When it builds a new image, it:
1. Tags the image
2. Creates a PR in this repo with an updated image tag
3. On approval and merge, the deploy workflow applies the new manifest

The `scripts/deploy.sh` handles the manual version of this.

### Summary: Files to Create
- `.github/workflows/deploy.yml` (new — the critical piece)
- Update `docs/secrets-setup.md` with `TALOSCONFIG_B64` instructions

---

## Testing the Full Pipeline

### Test at each stage

**After Stage 2:**
```bash
kubectl get nodes
# All 3 nodes should show NotReady
```

**After Stage 3a (Cilium):**
```bash
kubectl get nodes
# Nodes should become Ready

kubectl get pods -n kube-system
# cilium pods should be Running
```

**After Stage 3b (HCCM):**
```bash
kubectl get nodes -o wide
# Nodes should have cloud provider labels
```

**After Stage 3c (CSI):**
```bash
kubectl get storageclass
# hcloud-volumes should be default

# Create a test PVC and verify it binds
```

**After Stage 3d (Gateway):**
```bash
kubectl get gateway
# main-gateway should have an EXTERNAL-IP
```

**After Stage 4 (Test App):**
```bash
curl http://<load-balancer-ip>
# Should return nginx welcome page
```

**After Stage 5 (Automation):**
```bash
# Push a change to kubernetes/apps/test-app.yaml
git push

# Go to Actions tab in GitHub
# The deploy workflow should run
# Approve the production environment gate
# Verify the change deployed
```

---

## Troubleshooting

### Talos bootstrap issues
- **Error: connection refused** — Node not reachable. Check SSH access to NAT VM.
- **Error: invalid certificate** — LB IP mismatch. Verify `certSANs` in `talos/patches/patch-cp.yaml`.

### Helm install failures
- **Error: release already exists** — Use `helm upgrade --install` (as in the workflow examples).
- **Error: CRD validation failed** — Ensure cert-manager CRDs are installed first.

### kubectl access issues
- **Error: Unable to connect** — Check kubeconfig generation. Verify TALOSCONFIG_B64 is correct.
- **Error: unauthorized** — RBAC issue. Check HCCM is running.

### Network issues
- **PVC stays Pending** — CSI driver not installed or not ready. Check `kubectl get pods -n kube-system`.
- **HTTPRoute traffic not routing** — Gateway not ready. Check `kubectl get gateway`.

---

## Files to Create/Modify Summary

| File | Action | Stage | Priority |
|------|--------|-------|----------|
| `docs/bootstrap.md` | CREATE | 2 | Reference |
| `talos/patches/patch-cp.yaml` | UPDATE | 2 | Blocker |
| `kubernetes/hccm/values.yaml` | REPLACE | 3b | Blocker |
| `kubernetes/csi/values.yaml` | CREATE | 3c | Blocker |
| `kubernetes/cert-manager/values.yaml` | CREATE | 3e | High |
| `kubernetes/cert-manager/cluster-issuer.yaml` | CREATE | 3e | High |
| `kubernetes/gateway/gateway.yaml` | CREATE | 3d | Blocker |
| `kubernetes/apps/test-app.yaml` | UPDATE | 4 | High |
| `.github/workflows/deploy.yml` | CREATE | 5 | Blocker |
| `docs/secrets-setup.md` | UPDATE | 5 | Reference |

---

## Next Steps

1. **Complete Stage 2** — Bootstrap the cluster locally
2. **Complete Stage 3** — Install infrastructure components (can do manually first)
3. **Create manifest files** — Add missing YAML files and Helm values
4. **Create deploy workflow** — Add `.github/workflows/deploy.yml`
5. **Test automation** — Push a change and verify the workflow runs
