# Deployment Guide for FortiCNAPP Azure Agentless Workload Scanning

## Overview

This guide covers deployment of FortiCNAPP Azure Agentless Workload Scanning end-to-end.

Once deployed, agentless workload scanning delivers:

- VM-level CVE detection across running and stopped Azure VMs
- Package inventory for installed software on every scanned disk
- Disk-resident secrets detection (cloud credentials, tokens, keys left in user-data, config files, and home directories)
- Coverage for supported Linux distributions and Windows Server without installing or maintaining agents
- Per-region scanning infrastructure under customer control, with snapshot data never leaving the customer tenant
- Input into FortiCNAPP attack-path analysis when paired with the Azure Config + Activity Log integration

The scanner runs as a Container App Job in a dedicated scanning subscription. It snapshots target VM disks, mounts the snapshots on ephemeral scanning VMs, scans them, and discards both the temporary VMs and snapshots after each run.

This guide is scoped to the agentless deployment only. For the broader Azure integration (Config, Activity Log, DSPM, FortiGate Fabric, Alert Channels), see the <a href="https://github.com/andrewbearsley/forticnapp-azure-integration-guide" target="_blank">FortiCNAPP Azure Integration Guide</a>.

---

## Quick Start

### Step 1: Run preflight check

Run the Azure Agentless Workload Scanner Preflight Check to verify the scanning subscription has the required resource providers registered, sufficient quota for ephemeral scanning VMs, and the regions you plan to scan are available.

Run from <a href="https://portal.azure.com/#cloudshell/" target="_blank">Azure Cloud Shell</a> (Bash, not PowerShell). Cloud Shell is the easiest path because it ships with Azure CLI authenticated as your portal user and Python preinstalled, so the only extra dependency to install is `uv` (the package manager the preflight tool uses).

#### Which subscription to run from

The active `az` subscription doesn't gate what the preflight tool sees. The tool uses Azure SDK token-based auth and works against whatever IDs you pass via flags (`--scanning-subscription`, `--monitored-subscriptions`) or supply at the interactive prompts. Your Cloud Shell portal identity needs Reader (or higher) on the scanning subscription and on every monitored subscription you want it to enumerate.

Confirm which tenant Cloud Shell is bound to before running, so you don't accidentally check a different tenant:

```bash
az account show --query "{tenant:tenantId, user:user.name}" -o table
```

If you have access to multiple tenants and need to switch, run `az login --tenant <tenant_id>` from Cloud Shell first.

#### Install and run

```bash
# Install uv (one-liner from Astral; user-space, no sudo needed)
curl -LsSf https://astral.sh/uv/install.sh | sh
source $HOME/.local/bin/env

# Clone and run the preflight check
git clone https://github.com/lacework/terraform-azure-agentless-scanning.git
cd terraform-azure-agentless-scanning/preflight_check
uv run -m preflight_check
```

Interactive mode prompts for the scanning subscription, monitored subscriptions, regions, and NAT Gateway preference. Non-interactive equivalent:

```bash
uv run -m preflight_check \
  --scanning-subscription <scanning-subscription-id> \
  --monitored-subscriptions <monitored-sub-ids-comma-separated> \
  --regions <region-list> \
  --nat-gateway \
  --output-path ./preflight_report.json
```

The check writes a JSON report and prints a summary covering vCPU quotas (based on expected scanning VM count) and public IP quotas if `--no-nat-gateway` is used.

If you're using an ephemeral Cloud Shell session (no storage account mounted), `uv` will need to be reinstalled each session because `/home` is not persisted. With a mounted storage account, `~/.local/bin/uv` survives between sessions.

Reference: <a href="https://github.com/lacework/terraform-azure-agentless-scanning/tree/main/preflight_check" target="_blank">Azure Agentless Workload Scanner Preflight Check</a>

### Step 2: Install prerequisites

1. **Lacework CLI**: <a href="INSTALL-LACEWORK-CLI.md">Install and Configure Lacework CLI</a> (the Lacework Terraform provider reads `~/.lacework.toml` or `LW_*` env vars)
2. **Terraform**: <a href="INSTALL-TERRAFORM.md">Install Terraform</a>
3. **Azure CLI**: <a href="INSTALL-AZURE-CLI.md">Install and Configure Azure CLI</a>

### Step 3: Decide integration level

- **Tenant-level**: scans every subscription under a chosen Azure management group; single integration record; needs management-group-scoped permissions; auto-includes new subscriptions added under that scope.
- **Subscription-level**: scans one or more named subscriptions; subscription-scoped permissions; one integration record per scanning subscription.

Azure Landing Zone (ALZ) deployments typically use **tenant-level** because new subscriptions are added regularly under platform or workload management groups and the tenant scope picks them up automatically.

### Step 4: Gather information

| Field | Where to find |
|---|---|
| Azure tenant ID | `az account show --query tenantId -o tsv` |
| Scanning subscription ID (where the scanner runs) | `az account list --query "[].{id:id, name:name}" -o table` |
| Monitored subscription IDs (where VMs to scan live) | `az account list --query "[].{id:id, name:name}" -o table` |
| Management group ID (tenant-level only) | `az account management-group list -o table` |
| Azure regions for scanning infrastructure | Region of the VMs you need to scan. Each region you scan needs its own regional module instance. |

#### Permission delegation model

Confirm what you can do yourself versus what needs the platform team. See the <a href="#iam-permissions">IAM Permissions</a> section for the full breakdown. At a high level the apply principal needs Owner (or Contributor + User Access Administrator) at both the scanning subscription and at the monitored scope (subscription or management group), plus Application Administrator in Entra ID.

#### Storage Account network rules

The agentless module creates a Storage Account in the scanning subscription. The module exposes a queue inside that account, and `terraform apply` calls the queue data plane to seed it during the apply itself. The machine running `terraform apply` needs its public IP allowed on the Storage Account firewall, otherwise the data-plane call gets blocked at the network layer before RBAC is even evaluated. See <a href="#troubleshooting">Troubleshooting</a> for the symptoms and fix.

### Step 5: Get the Terraform configuration

Two ways to land Terraform code that's ready to apply: use the committed variants in this repo, or generate fresh via the Lacework CLI.

**Region behaviour matters.** The upstream `lacework/agentless-scanning/azure` module's `region` variable defaults to `westus2`. If you don't set it explicitly, every resource lands in West US 2 regardless of where your tenant operates. The committed variants below make `location` a required variable so this can't happen silently. If you generate via the CLI, pass `--regions <region>` explicitly.

#### Option 1: Apply the committed Terraform

Pick the variant matching your integration level from Step 3, edit the variables, and apply.

```bash
git clone https://github.com/andrewbearsley/forticnapp-azure-agentless-workload-scanning-guide.git
cd forticnapp-azure-agentless-workload-scanning-guide/terraform/<subscription-level|tenant-level>
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars
terraform init
terraform plan
terraform apply
```

Variant READMEs spell out per-level apply-time IAM, multi-region patterns, and tenant scoping notes: <a href="terraform/subscription-level/README.md">subscription-level</a> · <a href="terraform/tenant-level/README.md">tenant-level</a>.

#### Option 2: Generate fresh with `lacework generate`

Use this when you need a non-standard combination (existing AD application, custom storage account naming, multi-region from the start).

**Subscription-level:**
```bash
lacework generate cloud-account azure \
  --noninteractive \
  --agentless \
  --integration_level SUBSCRIPTION \
  --agentless_subscription_ids <monitored-subscription-ids> \
  --regions <region-list> \
  --subscription_id <scanning-subscription-id>
```

**Tenant-level:**
```bash
lacework generate cloud-account azure \
  --noninteractive \
  --agentless \
  --integration_level TENANT \
  --regions <region-list> \
  --subscription_id <scanning-subscription-id>
```

Flags:

- `--agentless`: provision the agentless workload scanning integration
- `--integration_level`: `SUBSCRIPTION` or `TENANT`. TENANT auto-scopes to the tenant's root management group; SUBSCRIPTION needs `--agentless_subscription_ids`.
- `--agentless_subscription_ids`: comma-separated list of subscriptions to scan (subscription-level only)
- `--regions`: comma-separated list of Azure regions where scanning infrastructure is deployed (one regional module per region). Always pass this. Without it the module defaults to `westus2`.
- `--subscription_id`: subscription where the scanning infrastructure (Container App Job, Storage, Key Vault, etc.) is deployed

Drop `--noninteractive` to walk through prompts instead. Terraform files land in `~/lacework/azure` by default (override with `--output`).

**Heads-up for single-region generate output.** The CLI emits `global = false` on the (only) module block for single-region deployments. With the upstream `lacework/agentless-scanning/azure` module 1.6.x this is broken: `terraform plan` errors at `azurerm_user_assigned_identity.sidekick is empty tuple` because the global resources are skipped but the locals still try to read them. Open `main.tf` and change `global = false` to `global = true` before running `terraform plan`. The committed variants in Option 1 already have this fix applied. Multi-region output is fine as-is: the first region is implicitly the global owner, additional regions pass `global_module_reference` to it. See <a href="#troubleshooting">Troubleshooting</a> for the full symptom and fix.

Reference: <a href="https://docs.fortinet.com/document/forticnapp/latest/cli-reference/635459/lacework-generate-cloud-account-azure" target="_blank">lacework generate cloud-account azure</a>

### Step 6: Authenticate with Azure CLI

```bash
az login --tenant <tenant_id>
az account set --subscription <scanning-subscription-id>
```

### Step 7: Deploy with Terraform

For the committed variants (Step 5 Option 1), you're already in the right directory after `cd terraform/<variant>`. For `lacework generate` output (Step 5 Option 2), `cd ~/lacework/azure` (or the path you passed via `--output`).

```bash
terraform init
terraform plan
terraform apply
```

If apply fails with a 403 on `azurerm_storage_queue` or on the Storage Account itself, see <a href="#troubleshooting">Troubleshooting</a>. Both are common, both have clean fixes, and both let you resume the same apply without destroying state.

### Step 8: Verify integration status

In the FortiCNAPP console, navigate to **Settings > Integrations > Cloud Accounts**. The agentless integration status displays as **Success** once the orchestrator has registered. Allow up to one full orchestrator cycle (the Container App Job runs hourly by default) for the first scan results to appear under **Vulnerabilities > Hosts**.

Reference: <a href="https://docs.fortinet.com/document/forticnapp/latest/administration-guide/42109/deploying-agentless-workload-scanning-on-azure" target="_blank">Deploying agentless workload scanning on Azure</a>

---

## How It Works

### Scanning lifecycle

1. The orchestrator Container App Job runs on an hourly cron and manages scanning state
2. It enumerates monitored subscriptions and identifies VMs due for scanning, including stopped and deallocated VMs
3. VM disks are snapshotted within the same region as the source VM (region-local, never cross-region)
4. The orchestrator provisions ephemeral scanning VMs and mounts the snapshots
5. Scanning VMs analyse the mounted disks for installed packages, known CVEs, and secrets
6. Scan results (metadata only) are written to the Storage Account in the scanning subscription
7. Lacework SaaS retrieves scan results from the Storage Account via a service principal with read-only access
8. Ephemeral scanning VMs and cloned snapshots are deleted at the end of each cycle

Each VM is scanned every 24 hours by default. The cadence is configurable to 6, 12, or 24 hours via the upstream module's `scan_frequency_hours` variable. The orchestrator wakes hourly regardless to manage state, requeue failures, and pick up newly-discovered VMs.

The Container App Job needs outbound HTTPS to Lacework APIs for configuration, diagnostics, and on-demand scan requests. Customer disk data never leaves the customer tenant. Only structured scan results (package lists, CVE matches, secret findings with file paths) are read by Lacework SaaS.

### Capability coverage

| Capability | Notes |
|---|---|
| CVE detection on running VMs | Snapshot-based, no agent or restart required |
| CVE detection on stopped / deallocated VMs | Same snapshot path; covers VMs missed by agent-based scanners |
| Package inventory | Captured per scan cycle |
| Secrets on disk | Cloud credentials, tokens, keys in user-data and on-disk files |
| Linux VMs | Common distributions (RHEL, Ubuntu, CentOS, SLES, Debian, Amazon Linux, Oracle Linux). See module docs for the current supported matrix. |
| Windows VMs | Windows Server (current supported versions in the module docs) |
| Encrypted disks | Supported when the scanning identity has access to the disk encryption key |
| Cross-region scanning | Not supported. Each scanned region needs a regional module instance in that region. |

Reference: <a href="https://docs.fortinet.com/document/forticnapp/latest/administration-guide/966589/agentless-workload-scanning" target="_blank">Agentless workload scanning</a> · <a href="https://docs.fortinet.com/document/forticnapp/latest/administration-guide/269317/agentless-workload-scanning-faqs" target="_blank">Agentless FAQs</a>

### Data residency

| Data | Lives where |
|---|---|
| VM disk contents (the raw bytes being scanned) | Scanning subscription only. Never leaves the customer tenant. |
| Disk snapshots | Scanning subscription, deleted at end of each scan cycle |
| Ephemeral scanning VMs | Scanning subscription, destroyed at end of each scan cycle |
| Scan results (package lists, CVE matches, secret findings) | Customer-side Storage Account in the scanning subscription, read by Lacework SaaS |
| Orchestrator logs | Log Analytics workspace in the scanning subscription |

---

## Architecture

### Per-region model

Scanning infrastructure is deployed per region. Each Azure region where you have VMs to scan needs its own regional module instance, because disk snapshots are region-local and cannot be cloned across regions. A single deployment with `--regions eastus,westeurope` produces two regional module instances sharing the same global resources (AD app, Key Vault, Storage).

### Resources provisioned

**Global resources (deployed once per integration):**

| Resource | Purpose |
|---|---|
| Azure AD Application + Service Principal | Authentication for Lacework SaaS to read scan results |
| Resource Group | Dedicated container for scanning infrastructure |
| Key Vault | Stores secrets used by the orchestrator |
| Storage Account + Blob Container | Stores scan results, queue for orchestration messages |
| Role assignments | Service principal and managed identity scoped roles at subscription or management group level |
| Custom role definitions | Snapshot management on monitored subscriptions; scanning operations in the scanning subscription |

**Regional resources (deployed per region):**

| Resource | Purpose |
|---|---|
| Container App Environment | Hosts the orchestrator Container App Job |
| Container App Job | Scheduled orchestrator, runs hourly |
| Virtual Network + Subnet | Network for scanning resources (or an existing VNet you specify) |
| Network Security Groups | Traffic control on the scanning subnet |
| Log Analytics Workspace | Container App Environment logs |
| Managed Identity | Lets Container App Jobs and scanning VMs access Azure resources |
| NAT Gateway + Public IP | Enabled by default. Outbound traffic from scanning VMs egresses via a single static IP rather than per-VM public IPs. |

**Ephemeral resources (created and destroyed each scan cycle, not managed by Terraform):**

| Resource | Lifecycle |
|---|---|
| Scanning VMs | Created by orchestrator, destroyed at end of cycle |
| Cloned disks (snapshots) | Created from source VM, destroyed at end of cycle |

### Deployment scenarios

- Tenant-level, single or multiple regions
- Subscription-level, single or multiple regions

### Optional module inputs

- **Custom VNet**: use an existing VNet and subnet instead of letting the module create one. Useful when network policy mandates centralised VNet management.
- **NAT Gateway**: enabled by default. Set `use_nat_gateway = false` to disable, in which case each scanning VM gets its own public IP. Most enterprise environments keep the NAT Gateway on for fewer firewall holes and a stable egress IP.
- **Private endpoint on the scanning Storage Account**: supported. Pair with `defaultAction: Deny` on the SA firewall for the locked-down posture.
- **Other inputs**: see <a href="https://registry.terraform.io/modules/lacework/agentless-scanning/azure/latest" target="_blank">Optional Inputs</a> on the Terraform module page.

### Terraform module

<a href="https://registry.terraform.io/modules/lacework/agentless-scanning/azure/latest" target="_blank">lacework/agentless-scanning/azure</a>

---

## IAM Permissions

Provisioning the agentless integration creates an AD application, role assignments, custom role definitions, a Key Vault, a Storage Account, a Container App Environment + Job, and networking resources. The deploying principal needs both control-plane permissions (to create the resources) and Storage Account data-plane permissions (to seed the orchestration queue during apply).

### Deployment-time: PIM pattern (recommended)

Platform team grants the roles as PIM-eligible. The apply principal activates for a 1 to 4 hour window, runs `terraform apply` (typically 10 to 20 minutes), activations auto-expire. Clean audit trail, no standing privilege.

| Role | Scope | Granted as |
|---|---|---|
| Owner (or Contributor + User Access Administrator) | Scanning subscription | PIM-eligible |
| Owner (or Contributor + User Access Administrator) | Monitored scope (management group for tenant-level, each subscription for subscription-level) | PIM-eligible |
| Storage Queue Data Contributor | Scanning Storage Account (after creation, see below) | Standing or PIM-eligible |
| Application Administrator | Entra ID directory | PIM-eligible |

Storage Queue Data Contributor is unusual because it has to be applied **after** the Storage Account exists, since the SA name has a random suffix per deployment. Either grant it on the scanning resource group ahead of time (covers any SA the module creates), or grant it on the SA after the first failed apply and re-run. See <a href="#troubleshooting">Troubleshooting</a>.

### Deployment-time: what the apply principal needs

What the apply principal needs at apply time, broken down by resource type:

| Permission | Scope | Purpose |
|---|---|---|
| Contributor | Scanning subscription | Create Resource Group, VNet + Subnet, NSGs, NAT Gateway + Public IP, Log Analytics workspace, Container App Environment, Container App Job, Managed Identity, Key Vault, Storage Account, Storage Blob Container |
| User Access Administrator | Scanning subscription | Assign managed identity roles, assign data-plane roles |
| Storage Queue Data Contributor | Scanning Storage Account (post-create) | Seed the orchestration queue during apply (data-plane operation) |
| Contributor + User Access Administrator | Management group (tenant-level) or each monitored subscription (subscription-level) | Create custom snapshot role and assign it to the scanning managed identity |
| Application Administrator | Entra ID | Create AD application for Lacework SaaS to read scan results |

Running Terraform as a service principal instead of a user: same RBAC at every scope, plus `Microsoft.Graph/Application.ReadWrite.OwnedBy` Graph API permission in Entra ID instead of Application Administrator.

### Deployment-time: granular alternative

If the platform team objects to Owner at the management group even via PIM, the granular shape:

| Role | Scope | Replaces |
|---|---|---|
| Reader + User Access Administrator + Contributor | Management group | Owner at MG |
| Contributor + User Access Administrator | Scanning subscription | (no change) |
| Storage Queue Data Contributor | Scanning Storage Account or RG | (no change) |
| Application Administrator (or `Application.ReadWrite.OwnedBy` Graph API) | Entra ID | (no change) |

Same outcome, narrower verbs.

### Runtime: what the scanner uses

The scanning identities are granted read-class access to monitored resources plus snapshot rights. No write permissions on monitored VMs.

| Identity | Permission | Scope |
|---|---|---|
| Service Principal (data loader) | Storage Blob Data Reader | Scanning Storage Account |
| Managed Identity (sidekick) | Storage Blob Data Contributor | Scanning Storage Account |
| Managed Identity (sidekick) | Key Vault Contributor | Scanning Key Vault |
| Managed Identity (sidekick) | Custom snapshot role | Monitored subscriptions or management group. Permissions: `Microsoft.Compute/disks/read`, `Microsoft.Compute/virtualMachines/read`, `Microsoft.Compute/snapshots/*`, `Microsoft.Resources/subscriptions/resourceGroups/read` |
| Managed Identity (sidekick) | Custom scanner role | Scanning subscription. Permissions: VM lifecycle, disk attach/detach, NIC config, storage account key access, managed identity assignment |

### Azure Policy DENY environments

In ALZ deployments with policy denying public IP creation tenant-wide, the only resource that typically needs an exemption is the NAT Gateway public IP in the scanning subscription. The exemption can be scoped narrowly:

- **Resource type**: `Microsoft.Network/publicIPAddresses`
- **Scope**: scanning subscription only
- **Justification**: NAT Gateway egress for scanning subscription. No public IPs on scanning VMs.

Reference: <a href="https://docs.fortinet.com/document/forticnapp/latest/administration-guide/991151/preparing-for-integration" target="_blank">Preparing for integration</a>

---

## Troubleshooting

Three friction patterns are worth flagging up front. The first hits at `terraform plan` and only affects `lacework generate` output for single-region deployments. The other two hit at `terraform apply` during data-plane queue creation and are caused by the agentless module creating a Storage Account with a randomised suffix and then calling the queue data plane during the apply itself. All three have clean, non-destructive fixes.

### Plan fails with `sidekick is empty tuple`

`terraform plan` errors at:

```
Error: Invalid index
  on .terraform/modules/lacework_agentless_scanning/main.tf line 138, in locals:
 138:   sidekick_principal_id = length(var.global_module_reference.sidekick_principal_id) > 0 ? var.global_module_reference.sidekick_principal_id : azurerm_user_assigned_identity.sidekick[0].principal_id
    │ azurerm_user_assigned_identity.sidekick is empty tuple
```

**Cause**: the module block has `global = false` but no `global_module_reference`. In `lacework/agentless-scanning/azure` 1.6.x, the global resources (Key Vault, Storage Account, managed identity, custom roles) are gated by `count = var.global ? 1 : 0`. With `global = false` and no reference to another module instance, the resources are skipped, but the locals still try to read `sidekick[0]` and fail.

**When this bites**: the `lacework generate cloud-account azure --agentless` CLI emits `global = false` even for single-region output. The committed variants in Option 1 of Step 5 already have this corrected.

**Fix**: open `main.tf` and change `global = false` to `global = true` on the single module block (or on the first module block if you have multiple regions). Re-run `terraform plan`. The first module is the implicit "global owner" that creates the shared resources; subsequent regional modules pass `global_module_reference = module.<first>` and keep `global = false`.

No state surgery needed because plan failed before any resources were created.

### Apply fails with 403 on `azurerm_storage_queue` create

The module creates the scanning Storage Account, then creates a queue inside it via the data plane. The deploying principal needs `Storage Queue Data Contributor` at the SA scope, not just subscription Owner, because queue create is a data-plane operation rather than control-plane.

**When this bites:**

- First deploy in an environment where the principal has Owner but no data-plane assignments
- After `terraform destroy` + reapply, because the new SA has a fresh resource ID and prior grants are gone with it

**Error signature** (paraphrased):
```
Error: retrieving Queue "lacework-queue-..." (Account "laceworkstorageXXXXXXXX"):
unexpected status 403
AuthorizationFailure: This request is not authorized to perform this operation.
```

**Fix**: grant the role on the new SA, wait ~30 seconds for the grant to propagate, re-run `terraform apply`. Terraform picks up where it left off.

```bash
az role assignment create \
  --assignee <objectId-of-deploying-principal> \
  --role "Storage Queue Data Contributor" \
  --scope /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/laceworkstorageXXXXXXXX
```

To avoid this on the next destroy + reapply cycle, grant `Storage Queue Data Contributor` on the scanning resource group ahead of time. The grant covers any SA the module creates inside it.

### Apply still 403s with RBAC in place

If the Storage Account has `defaultAction: Deny` with an IP allowlist (common in government and regulated environments using Azure Policy), data-plane queue calls get blocked at the network layer before RBAC is even evaluated. Diagnostic: you can see the queue exists in the portal but cannot browse INTO it from your shell.

**Inbound source IPs that need to be allowed on the SA firewall:**

| Source | Why |
|---|---|
| Apply-time: the deploying principal's actual egress IP | Terraform's queue data-plane calls go out from this IP. Often not what you'd guess due to corporate proxies, SNAT pools, NAT, Cloud Shell egress, etc. |
| Runtime: Lacework SaaS egress IPs | Lacework reads scan results from the SA after each scan cycle. Documented in the Lacework setup docs. |
| Runtime: scanning subscription VNet | The Container App Job processes the orchestration queue from inside the VNet. Add as a VNet rule. |

**Fix options for the apply-time block:**

1. Identify Terraform's actual egress IP from the same shell terraform is running in:
   ```bash
   curl -s ifconfig.me
   ```
   Add the result to the SA firewall.
2. Run Terraform from inside the VNet (jumpbox or bastion in the scanning subscription) so traffic flows via the existing VNet rule.
3. Temporarily set `defaultAction: Allow` during the change window, flip back to `Deny` after apply completes.

**Locked-down posture after apply:** `defaultAction: Deny` + Lacework SaaS allowlist + scanning subscription VNet rule. The apply-time admin IP can be removed once Terraform is no longer running.

### Don'ts

- Don't enable `allow_shared_key_access` on the Storage Account to work around either cause. RBAC + data-plane assignments solve it cleanly.
- Don't disable private endpoint enforcement to work around the firewall block.
- Don't leave `defaultAction: Allow` after apply completes.
- Don't grant the apply principal Storage Account Contributor as a substitute for Storage Queue Data Contributor. Storage Account Contributor is control-plane, the 403 is data-plane.

---

## Resources

- <a href="https://docs.fortinet.com/document/forticnapp/latest/administration-guide/966589/agentless-workload-scanning" target="_blank">FortiCNAPP: Agentless workload scanning</a>
- <a href="https://docs.fortinet.com/document/forticnapp/latest/administration-guide/42109/deploying-agentless-workload-scanning-on-azure" target="_blank">FortiCNAPP: Deploying agentless workload scanning on Azure</a>
- <a href="https://docs.fortinet.com/document/forticnapp/latest/administration-guide/991151/preparing-for-integration" target="_blank">FortiCNAPP: Preparing for integration</a>
- <a href="https://docs.fortinet.com/document/forticnapp/latest/administration-guide/269317/agentless-workload-scanning-faqs" target="_blank">FortiCNAPP: Agentless workload scanning FAQs</a>
- <a href="https://registry.terraform.io/modules/lacework/agentless-scanning/azure/latest" target="_blank">Terraform Registry: lacework/agentless-scanning/azure</a>
- <a href="https://github.com/lacework/terraform-azure-agentless-scanning/tree/main/preflight_check" target="_blank">Agentless Preflight Check</a>
- <a href="https://github.com/andrewbearsley/forticnapp-azure-integration-guide" target="_blank">Sibling guide: FortiCNAPP Azure Integration (Config, Activity Log, DSPM, FortiGate, Alert Channels)</a>
