# Remote state (partial configuration). Initialise with:
#
#   terraform init -backend-config=backend.hcl
#
# (copy backend.hcl.example to backend.hcl and edit). For offline checks use
# `terraform init -backend=false` / `terraform validate`.
terraform {
  backend "s3" {
    key          = "uniflow/terraform.tfstate"
    use_lockfile = true
  }
}
