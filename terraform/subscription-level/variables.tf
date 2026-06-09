variable "scanning_subscription_id" {
  type        = string
  description = "Azure subscription ID where the agentless scanning infrastructure is deployed (Container App Job, Key Vault, Storage Account, networking)."
}

variable "monitored_subscription_ids" {
  type        = list(string)
  description = "List of subscription IDs whose VMs are scanned. Plain UUIDs only (the module's /subscriptions/ prefix is added in main.tf)."

  validation {
    condition     = length(var.monitored_subscription_ids) > 0
    error_message = "monitored_subscription_ids must contain at least one subscription ID."
  }
}

variable "location" {
  type        = string
  description = "Azure region where scanning infrastructure is deployed (e.g. australiaeast). Must be set explicitly. The upstream module's region variable defaults to westus2 if not provided."

  validation {
    condition     = length(var.location) > 0
    error_message = "location must be set explicitly. Without it the upstream module defaults to westus2."
  }
}
