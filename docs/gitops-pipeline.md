# GitOps Pipeline Overview

`whoknows_infra` is the source of truth for all infrastructure and deployment state.
The other two repos trigger changes into it — they never manage infra themselves.

## Architecture

```
whoknows_ripmarkus   →   tag v*   →   build image → deploy to cluster
                                          ↓ (major bump only)
                                       open PR in whoknows_infra

whoknows_infra       →   PR on terraform/**   →   terraform plan (comment on PR)
                     →   merge to main        →   terraform apply (manual approval)

whoknows_monitoring  →   push to main   →   SSH deploy to monitoring VM
                                             (future: kubectl apply to cluster)
```

## Workflows

| Repo | File | Trigger |
|---|---|---|
| whoknows_infra | `.github/workflows/terraform.yml` | push/PR on `terraform/**` |
| whoknows_ripmarkus | `.github/workflows/deploy.yml` | git tag `v*` |
| whoknows_monitoring | `.github/workflows/monitoring.yml` | push to `main` |

## Secrets matrix

| Secret | whoknows_infra | whoknows_ripmarkus | whoknows_monitoring |
|---|:---:|:---:|:---:|
| `HCLOUD_TOKEN` | ✓ | ✓ | |
| `TF_CLOUD_TOKEN` | ✓ | ✓ | |
| `TALOSCONFIG_B64` | | ✓ | (future) |
| `DEPLOY_REPO_TOKEN` | | ✓ | |
| `APP_NAME` | | ✓ | |
| `APP_DOMAIN` | | ✓ | |
| `SSH_KEY` | | | ✓ |
| `MONITORING_SERVER_USER` | | | ✓ |
| `MONITORING_SERVER_IP` | | | ✓ |
| `APP_SERVER_USER` | | | ✓ |
| `APP_SERVER_IP` | | | ✓ |

## Setup order

1. Terraform Cloud — see [terraform-cloud-setup.md](terraform-cloud-setup.md)
2. Infra secrets — see [secrets-setup.md](secrets-setup.md)
3. App repo secrets and deploy — see `whoknows_ripmarkus/docs/deploy.md`
4. Monitoring — see `whoknows_monitoring/docs/monitoring-deploy.md`
