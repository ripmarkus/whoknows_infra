terraform {
  backend "s3" {
    endpoints = {
      s3 = "https://fsn1.your-objectstorage.com"
    }
    bucket = "whoknows-tfstate"
    key    = "whoknows_infra/terraform.tfstate"
    region = "fsn1"

    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    force_path_style            = true
  }
}
