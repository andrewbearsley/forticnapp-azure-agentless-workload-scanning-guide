variable "scanning_subscription_id" {
  type        = string
  description = "Azure subscription ID where the agentless scanning infrastructure is deployed (Container App Job, Key Vault, Storage Account, networking)."
}

variable "location" {
  type        = string
  description = "Azure region where scanning infrastructure is deployed (e.g. australiaeast). Must be set explicitly. The upstream module's region variable defaults to westus2 if not provided."

  validation {
    condition     = length(var.location) > 0
    error_message = "location must be set explicitly. Without it the upstream module defaults to westus2."
  }
}
