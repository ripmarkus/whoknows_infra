# GitOps Implementation Checklist

## Stage 1: Infrastructure Provisioning ✅
- [x] Terraform CI/CD workflow (`terraform.yml`)
- [x] Terraform Cloud backend
- [x] Hetzner resources (VPC, nodes, LB)

---

## Stage 2: Cluster Bootstrap (Manual, One-Time)
- [ ] Get infrastructure outputs (`terraform output`)
- [ ] Update hardcoded LB IP in `talos/patches/patch-cp.yaml`
- [ ] Generate Talos secrets and configs
- [ ] Apply configs to nodes
- [ ] Bootstrap etcd
- [ ] Generate kubeconfig
- [ ] Save `TALOSCONFIG_B64` to GitHub Actions secret
- [ ] Create `docs/bootstrap.md` (reproduction guide)

**Dependencies:** Must complete before Stage 3

**Estimated time:** 30 minutes (one-time)

---

## Stage 3: Kubernetes Infrastructure Components
- [ ] **3a. Cilium CNI**
  - [x] `kubernetes/cilium/values.yaml` exists
  - [ ] Helm install (manual test)
  - [ ] Verify: pods running

- [ ] **3b. Hetzner Cloud Controller Manager**
  - [ ] Create `kubernetes/hccm/values.yaml` (replace current snippet)
  - [ ] Create `hcloud` Kubernetes secret
  - [ ] Helm install (manual test)
  - [ ] Verify: nodes have cloud labels

- [ ] **3c. Hetzner CSI Driver**
  - [ ] Create `kubernetes/csi/values.yaml`
  - [ ] Helm install (manual test)
  - [ ] Verify: PVC binds

- [ ] **3d. Gateway API**
  - [ ] Create `kubernetes/gateway/gateway.yaml`
  - [ ] Apply Gateway API CRDs
  - [ ] kubectl apply gateway
  - [ ] Verify: gateway has external IP

- [ ] **3e. cert-manager + HTTPS**
  - [ ] Create `kubernetes/cert-manager/values.yaml`
  - [ ] Create `kubernetes/cert-manager/cluster-issuer.yaml`
  - [ ] Helm install (manual test)
  - [ ] Verify: ClusterIssuer ready

**Dependencies:** Stages 2 complete. Install in order (3a → 3b → 3c → 3d → 3e)

**Estimated time:** 45 minutes total

---

## Stage 4: Application Deployment
- [ ] Update `kubernetes/apps/test-app.yaml` (add HTTPRoute)
- [ ] kubectl apply test-app
- [ ] Verify: nginx accessible via LB IP
- [ ] Create `kubernetes/apps/whoknows.yaml` (for real app)

**Dependencies:** Stage 3 complete

**Estimated time:** 15 minutes

---

## Stage 5: Full CI/CD Automation
- [ ] Add GitHub Actions secret: `TALOSCONFIG_B64`
- [ ] Add GitHub Actions secret: `LOAD_BALANCER_IP`
- [ ] Add GitHub Actions secret: `HCLOUD_NETWORK_ID`
- [ ] Create `.github/workflows/deploy.yml`
- [ ] Update `docs/secrets-setup.md`
- [ ] Test: push change to `kubernetes/` → workflow runs
- [ ] Test: approve production gate → manifests deploy

**Dependencies:** Stages 2-4 complete

**Estimated time:** 30 minutes

---

## Files to Create/Modify

### High Priority (Blockers)
```
kubernetes/
├── gateway/
│   └── gateway.yaml                    # CREATE
├── hccm/
│   └── values.yaml                     # REPLACE (currently just env snippet)
├── csi/
│   └── values.yaml                     # CREATE
└── apps/
    └── test-app.yaml                   # UPDATE (add HTTPRoute)

.github/workflows/
└── deploy.yml                          # CREATE (critical piece)

talos/patches/
└── patch-cp.yaml                       # UPDATE (remove hardcoded IP)
```

### Medium Priority (Reference/Docs)
```
docs/
├── bootstrap.md                        # CREATE
├── gitops-implementation-guide.md      # CREATE (this guide)
└── secrets-setup.md                    # UPDATE (add TALOSCONFIG_B64)

kubernetes/cert-manager/
├── values.yaml                         # CREATE
└── cluster-issuer.yaml                 # CREATE
```

---

## GitHub Actions Secrets to Add

| Name | Source | Used By |
|------|--------|---------|
| `TALOSCONFIG_B64` | `base64 talos/generated/talosconfig` | `deploy.yml` (get kubeconfig) |
| `LOAD_BALANCER_IP` | `terraform output load_balancer_ip` | `deploy.yml` (talosctl kubeconfig) |
| `HCLOUD_TOKEN` | Hetzner console | `deploy.yml`, `terraform.yml` |
| `HCLOUD_NETWORK_ID` | Hetzner console / Terraform state | `deploy.yml` (create secret) |
| `TF_TOKEN_app_terraform_io` | Already exists | `deploy.yml` (if fetching outputs) |

---

## Manual Commands (Reference)

### Stage 2 essentials
```bash
cd terraform
terraform output load_balancer_ip
terraform output nat_vm_ip

# Update patch-cp.yaml with LB IP, then:
talosctl gen config whoknows https://<LB_IP>:6443 \
  --with-secrets talos/generated/secrets.yaml \
  --config-patch-control-plane @talos/patches/patch-cp.yaml \
  --config-patch @talos/patches/patch.yaml \
  --output talos/generated/

# Apply configs to nodes (via SSH/ProxyJump to NAT VM)
# Bootstrap etcd
# Generate kubeconfig
```

### Stage 3 commands (one of each)
```bash
# Cilium
helm repo add cilium https://helm.cilium.io/
helm upgrade --install cilium cilium/cilium \
  --namespace kube-system \
  --values kubernetes/cilium/values.yaml --version 1.16.x

# HCCM (after creating secret)
helm repo add hcloud https://charts.hetzner.cloud
helm upgrade --install hcloud-cloud-controller-manager hcloud/hcloud-cloud-controller-manager \
  --namespace kube-system --values kubernetes/hccm/values.yaml

# CSI
helm repo add hcloud-csi https://charts.hetzner.cloud
helm upgrade --install hcloud-csi hcloud/hcloud-csi \
  --namespace kube-system --values kubernetes/csi/values.yaml

# Gateway
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml
kubectl apply -f kubernetes/gateway/

# cert-manager
helm repo add jetstack https://charts.jetstack.io
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --values kubernetes/cert-manager/values.yaml --set installCRDs=true
kubectl apply -f kubernetes/cert-manager/
```

### Stage 4
```bash
kubectl apply -f kubernetes/apps/test-app.yaml
curl http://<LB_IP>
```

### Stage 5 test
```bash
# Push change to kubernetes/
git push

# Go to GitHub Actions → deploy workflow
# Approve production gate
# Verify deployment
```

---

## Estimated Total Time

| Stage | Time | Type |
|-------|------|------|
| 1 | ✅ Done | CI/CD |
| 2 | 30 min | Manual |
| 3 | 45 min | Manual + files |
| 4 | 15 min | Files + manual |
| 5 | 30 min | Files + CI/CD |
| **Total** | **~2 hours** | |

---

## Success Criteria

### Minimum viable pipeline
- [x] Terraform provisions infrastructure
- [ ] Cluster bootstraps and has all nodes Ready
- [ ] Kubernetes infra components installed (Cilium, HCCM, CSI, Gateway)
- [ ] Test app accessible via `curl http://<LB_IP>`
- [ ] Deploy workflow runs on push to `kubernetes/`

### Full GitOps
- [ ] Cluster state matches git repository
- [ ] All infrastructure changes flow through CI/CD
- [ ] Manual `kubectl apply` is discouraged (all changes via git + workflow)

---

## Common Issues

| Problem | Cause | Fix |
|---------|-------|-----|
| Talos bootstrap fails | LB IP mismatch | Update `certSANs` in `patch-cp.yaml` |
| Nodes not Ready | Cilium not installed | Run Cilium helm install |
| PVC stays Pending | CSI driver missing | Install Hetzner CSI |
| HTTPRoute traffic fails | Gateway not ready | Check `kubectl get gateway` |
| Workflow kubeconfig error | `TALOSCONFIG_B64` malformed | Verify base64 encoding |

---

## Documentation

- **[gitops-implementation-guide.md](docs/gitops-implementation-guide.md)** — Full step-by-step walkthrough
- **[bootstrap.md](docs/bootstrap.md)** — Talos cluster bootstrap (to be created)
- **[secrets-setup.md](docs/secrets-setup.md)** — GitHub Actions secrets (to be updated)
- **[terraform-cloud-setup.md](docs/terraform-cloud-setup.md)** — Already exists
- **[gitops-pipeline.md](docs/gitops-pipeline.md)** — Already exists (3-repo architecture)
