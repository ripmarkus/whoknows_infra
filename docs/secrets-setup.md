# Secrets Setup — whoknows_infra

Add these secrets under **Settings → Secrets and variables → Actions** in the `whoknows_infra` repo.

## HCLOUD_TOKEN

1. Hetzner Cloud console → project → **Security → API Tokens**
2. Generate a token with **Read & Write** permissions
3. Add as `HCLOUD_TOKEN`

## TF_CLOUD_TOKEN

See [terraform-cloud-setup.md](terraform-cloud-setup.md) — step 3.

## GitHub Environment: production

The `apply` job is gated by a GitHub Environment named `production`.

1. Repo **Settings → Environments → New environment** → name it `production`
2. Enable **Required reviewers** and add yourself
3. Optionally restrict to the `main` branch

Without this environment the apply job runs unattended on every merge to main.
