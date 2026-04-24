# Terraform Cloud Setup

Remote state is stored in Terraform Cloud (free tier). CI authenticates with a single token.

## 1. Create account and organization

1. Sign up at https://app.terraform.io
2. Create an organization — note the name, you'll need it in step 4.

## 2. Create workspace

1. New workspace → **CLI-driven workflow** → name it `whoknows-infra`
2. In workspace settings → **General** → set **Execution Mode** to **Local**
   - State is stored in TFC, but `plan`/`apply` runs on the GitHub runner

## 3. Generate a token

1. In TFC: User icon → **User Settings** → **Tokens** → **Create an API token**
2. Copy the token — it's only shown once

## 4. Update backend.tf

In `terraform/backend.tf`, replace `your-org` with your actual organization name:

```hcl
terraform {
  cloud {
    organization = "your-actual-org-name"
    workspaces {
      name = "whoknows-infra"
    }
  }
}
```

## 5. Initialize locally

```bash
export TF_TOKEN_app_terraform_io=<your-token>
terraform -chdir=terraform init
```

If you have an existing local `terraform.tfstate`, run `init -migrate-state` instead to upload it:

```bash
terraform -chdir=terraform init -migrate-state
```

After a successful init, delete the local state files — they are no longer the source of truth:

```bash
rm terraform/terraform.tfstate terraform/terraform.tfstate.backup
```

## 6. Add the token as a GitHub secret

Add `TF_CLOUD_TOKEN` to **both** repos that run terraform:

| Repo | Secret name | Value |
|---|---|---|
| `whoknows_infra` | `TF_CLOUD_TOKEN` | token from step 3 |
| `whoknows_ripmarkus` | `TF_CLOUD_TOKEN` | same token |
