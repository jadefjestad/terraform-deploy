# Backend config for the state-backend module's OWN state.
#
# After initial bootstrap (local state), migrate with:
#   terraform init -backend-config="backend.hcl" -migrate-state
#
storage_account_name = "stterraformstateorg"
container_name       = "platform-engineering"
key                  = "state-backend.tfstate"
resource_group_name  = "rg-terraform-state"
