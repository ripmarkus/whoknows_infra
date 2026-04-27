terraform {
  cloud {
    organization = "ripmarkus"
    workspaces {
      name = "whoknows-infra"
    }
  }
}
