terraform {
  required_providers {
    lacework = {
      source  = "lacework/lacework"
      version = "~> 2.0"
    }
  }
}

provider "azuread" {
}

provider "azurerm" {
  subscription_id = var.scanning_subscription_id
  features {
  }
}

locals {
  monitored_subscription_resource_ids = [for s in var.monitored_subscription_ids : "/subscriptions/${s}"]
}

# Single-region deployment.
#
# global = true tells the module to create both the global resources (AD app,
# Key Vault, Storage Account, custom role definitions) and the regional
# resources for var.location in one go. This matches the module's own
# examples/subscription-single-region/ reference pattern.
#
# To scan additional regions, add a second module block alongside this one with
# global = false and global_module_reference = module.lacework_agentless_scanning.
# That additional region reuses the global resources created here instead of
# trying to create its own. Example:
#
#   module "lacework_agentless_scanning_secondary" {
#     source                         = "lacework/agentless-scanning/azure"
#     version                        = "~> 1.6"
#     create_log_analytics_workspace = false
#     global                         = false
#     global_module_reference        = module.lacework_agentless_scanning
#     integration_level              = "SUBSCRIPTION"
#     region                         = "australiasoutheast"
#     scanning_subscription_id       = var.scanning_subscription_id
#   }
module "lacework_agentless_scanning" {
  source                         = "lacework/agentless-scanning/azure"
  version                        = "~> 1.6"
  create_log_analytics_workspace = false
  global                         = true
  integration_level              = "SUBSCRIPTION"
  region                         = var.location
  scanning_subscription_id       = var.scanning_subscription_id
  included_subscriptions         = local.monitored_subscription_resource_ids
}
