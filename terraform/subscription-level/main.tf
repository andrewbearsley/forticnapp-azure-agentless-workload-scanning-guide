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
# To scan additional regions, copy this module block, rename it
# (e.g. lacework_agentless_scanning_<region>), change `region`, and add
# `global_module_reference = module.lacework_agentless_scanning` so the new
# region reuses the global resources (AD app, Key Vault, Storage Account,
# custom roles) created by the first module.
module "lacework_agentless_scanning" {
  source                         = "lacework/agentless-scanning/azure"
  version                        = "~> 1.6"
  create_log_analytics_workspace = false
  global                         = false
  integration_level              = "SUBSCRIPTION"
  region                         = var.location
  scanning_subscription_id       = var.scanning_subscription_id
  included_subscriptions         = local.monitored_subscription_resource_ids
}
