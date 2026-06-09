# Subscription-level agentless workload scanning

Deploys FortiCNAPP Azure Agentless Workload Scanning against one or more named Azure subscriptions, with scanning infrastructure landing in a dedicated scanning subscription.

Generated from the `lacework generate cloud-account azure` command below, then committed with literal values extracted as variables:

```bash
lacework generate cloud-account azure \
  --noninteractive \
  --agentless \
  --integration_level SUBSCRIPTION \
  --agentless_subscription_ids <monitored-subs> \
  --regions <region> \
  --subscription_id <scanning-sub>
```

## What this deploys

Per the upstream `lacework/agentless-scanning/azure` module:

- One Azure AD application + service principal granted Reader and the custom snapshot role on each monitored subscription
- One Resource Group, Key Vault, and Storage Account in the scanning subscription (global resources)
- Regional resources for `var.location`: VNet + Subnet, NSGs, NAT Gateway + Public IP, Container App Environment, Container App Job, Managed Identity
- Two custom role definitions (snapshot on monitored subs, scanner on the scanning sub)
- One FortiCNAPP cloud-account integration record bound to the AD application

The orchestrator Container App Job runs hourly. Each VM is scanned every 24 hours by default (configurable to 6, 12, or 24 via the upstream `scan_frequency_hours` variable).

## Region behaviour

`location` is a required variable. The upstream module's `region` variable defaults to `westus2`, so leaving `location` unset would land every resource in West US 2. This variant validates that `location` is non-empty.

For multi-region scanning, copy the `module "lacework_agentless_scanning"` block in `main.tf`, give the copy a new name, change `region`, and add `global_module_reference = module.lacework_agentless_scanning` so the additional region reuses the global resources created by the first module instead of trying to create its own.

## Prerequisites

1. <a href="../../INSTALL-LACEWORK-CLI.md">Lacework CLI configured</a> (the Lacework Terraform provider reads `~/.lacework.toml` or `LW_*` env vars)
2. <a href="../../INSTALL-AZURE-CLI.md">Azure CLI</a> logged in via `az login --tenant <tenant_id>`
3. <a href="../../INSTALL-TERRAFORM.md">Terraform</a>

## Apply-time permissions

The principal running `terraform apply` needs:

- **Contributor** on the scanning subscription (Resource Group, VNet, NAT Gateway + Public IP, NSGs, Container App, Key Vault, Storage Account)
- **User Access Administrator** on the scanning subscription (managed identity and data-plane role assignments)
- **Storage Queue Data Contributor** on the scanning Storage Account or its parent resource group (data-plane queue seeding during apply)
- **Contributor + User Access Administrator** on each monitored subscription (custom snapshot role definition + assignment)
- **Application Administrator** in Entra ID, or `Application.ReadWrite.OwnedBy` Microsoft Graph permission if running as a service principal

See the <a href="../../README.md#iam-permissions">main guide's IAM Permissions section</a> for the PIM pattern and per-resource breakdown.

## Apply

```bash
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: set scanning_subscription_id, location, monitored_subscription_ids
terraform init
terraform plan
terraform apply
```

If apply fails with a 403 on `azurerm_storage_queue` or the Storage Account itself, see the <a href="../../README.md#troubleshooting">Troubleshooting section</a> in the main guide. Both are common, both have clean fixes that don't require a destroy.

## Runtime permissions

The created service principal and managed identity get read-class access plus snapshot rights:

- Service Principal (data loader): Storage Blob Data Reader on the scanning Storage Account
- Managed Identity (sidekick): Storage Blob Data Contributor + Key Vault Contributor in the scanning subscription
- Managed Identity (sidekick): Custom snapshot role on each monitored subscription (`Microsoft.Compute/disks/read`, `Microsoft.Compute/virtualMachines/read`, `Microsoft.Compute/snapshots/*`, `Microsoft.Resources/subscriptions/resourceGroups/read`)
- Managed Identity (sidekick): Custom scanner role in the scanning subscription (VM lifecycle, disk attach/detach, NIC config, storage account key access, managed identity assignment)

No write permissions on monitored VMs or disks.

## Verify

Console: **Settings > Integrations > Cloud Accounts**. Status flips to **Success** once the orchestrator registers. First scan results appear under **Vulnerabilities > Hosts** within one orchestrator cycle (default hourly).

## References

- <a href="https://registry.terraform.io/modules/lacework/agentless-scanning/azure/latest" target="_blank">lacework/agentless-scanning/azure</a>
- <a href="https://docs.fortinet.com/document/forticnapp/latest/administration-guide/42109/deploying-agentless-workload-scanning-on-azure" target="_blank">FortiCNAPP: Deploying agentless workload scanning on Azure</a>
