###############################################################################
# Terraform — Remote State Backend Bootstrap
#
# This Terraform configuration manages the PIPELINE's OWN infrastructure:
#   • The shared state storage account used by ALL application teams
#   • The resource group that holds it
#
# This is separate from the app teams' Terraform. It is used once during
# bootstrap and then managed by the platform team.
#
# Usage:
#   cd state-backend/
#   terraform init -backend-config="backend.hcl"
#   terraform plan
#   terraform apply
###############################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }

  # After initial bootstrap, migrate state into itself:
  #   terraform init -backend-config="backend.hcl" -migrate-state
  backend "azurerm" {}
}

provider "azurerm" {
  features {}
  use_oidc = true
}

# ── Variables ────────────────────────────────────────────────────────────────

variable "location" {
  description = "Azure region for the state backend resources"
  type        = string
  default     = "westus2"
}

variable "resource_group_name" {
  description = "Resource group for Terraform state storage"
  type        = string
  default     = "rg-terraform-state"
}

variable "storage_account_name" {
  description = "Storage account name (must be globally unique, 3-24 chars, lowercase alphanumeric)"
  type        = string
  default     = "stterraformstateorg"
}

variable "team_containers" {
  description = "List of blob containers to create — one per application team"
  type        = list(string)
  default     = ["default"]
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default = {
    ManagedBy = "Terraform"
    Purpose   = "terraform-state-backend"
    Owner     = "platform-engineering"
  }
}

# ── Resource Group ───────────────────────────────────────────────────────────

resource "azurerm_resource_group" "state" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# ── Storage Account ──────────────────────────────────────────────────────────

resource "azurerm_storage_account" "state" {
  name                          = var.storage_account_name
  resource_group_name           = azurerm_resource_group.state.name
  location                      = azurerm_resource_group.state.location
  account_tier                  = "Standard"
  account_replication_type      = "GRS"     # geo-redundant for state durability
  min_tls_version               = "TLS1_2"
  public_network_access_enabled = true      # required for GitHub-hosted runners (Iteration 1)
  # For future: restrict to self-hosted runner VNet via network_rules

  blob_properties {
    versioning_enabled = true  # point-in-time recovery for state files

    delete_retention_policy {
      days = 30               # soft-delete protects against accidental deletion
    }

    container_delete_retention_policy {
      days = 14
    }
  }

  tags = var.tags
}

# ── Blob Containers (one per team) ──────────────────────────────────────────

resource "azurerm_storage_container" "team" {
  for_each              = toset(var.team_containers)
  name                  = each.value
  storage_account_id    = azurerm_storage_account.state.id
  container_access_type = "private"
}

# ── Diagnostic: enable Storage Analytics logging ─────────────────────────────
# (Optional — uncomment to enable audit logging on the state storage)
#
# resource "azurerm_monitor_diagnostic_setting" "state_storage" {
#   name                       = "state-storage-diag"
#   target_resource_id         = azurerm_storage_account.state.id
#   log_analytics_workspace_id = var.log_analytics_workspace_id
#
#   enabled_log {
#     category = "StorageRead"
#   }
#   enabled_log {
#     category = "StorageWrite"
#   }
#   enabled_log {
#     category = "StorageDelete"
#   }
# }

# ── Outputs ──────────────────────────────────────────────────────────────────

output "storage_account_name" {
  description = "State storage account name (use in backend-config)"
  value       = azurerm_storage_account.state.name
}

output "resource_group_name" {
  description = "State resource group name (use in backend-config)"
  value       = azurerm_resource_group.state.name
}

output "storage_account_id" {
  description = "Full resource ID of the state storage account"
  value       = azurerm_storage_account.state.id
}

output "containers" {
  description = "Map of team → container name"
  value       = { for k, v in azurerm_storage_container.team : k => v.name }
}
