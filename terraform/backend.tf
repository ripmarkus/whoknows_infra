terraform {
  cloud {
    organization = "your-org"
    workspaces {
      name = "whoknows-infra"
    }
  }
}
