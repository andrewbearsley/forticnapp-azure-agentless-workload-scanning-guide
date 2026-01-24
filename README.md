# Deployment Guide for FortiCNAPP Azure Agentless Workload Scanning

## Overview

This deployment guide provides step-by-step instructions for deploying FortiCNAPP Azure Agentless Workload Scanning. Agentless workload scanning enables vulnerability scanning for Azure virtual machines without installing agents on target systems.

This guide covers prerequisites, deployment steps, architecture details, and configuration options for Azure environments.

## Quick Start

### Step 1: Run Preflight Check

Run the Azure Agentless Workload Scanner Preflight Check tool to verify your Azure environment is properly configured.

**Option 1 - Local machine (macOS):**
```bash
# Clone and run the preflight check tool
git clone https://github.com/lacework/terraform-azure-agentless-scanning.git
cd terraform-azure-agentless-scanning/preflight_check
# Follow instructions in the preflight check repository
```

**Option 2 - Azure Cloud Shell:**

1. Open Azure Cloud Shell from the Azure portal
2. Select **Bash** (not PowerShell)
3. Clone and run the preflight check:
```bash
git clone https://github.com/lacework/terraform-azure-agentless-scanning.git
cd terraform-azure-agentless-scanning/preflight_check
# Follow instructions in the preflight check repository
```

Reference: [Azure Agentless Workload Scanner Preflight Check](https://github.com/lacework/terraform-azure-agentless-scanning/tree/main/preflight_check)

### Step 2: Install Prerequisites

Install and configure the required tools:

1. **Lacework CLI**: [Install and Configure Lacework CLI](INSTALL-LACEWORK-CLI.md)
2. **Terraform**: [Install Terraform](INSTALL-TERRAFORM.md) (version 1.9 or later required)
3. **Azure CLI**: [Install and Configure Azure CLI](INSTALL-AZURE-CLI.md)

### Step 3: Gather Information

Gather the following information before generating Terraform configuration:

- **Integration level**: `SUBSCRIPTION` or `TENANT`
  - Example: `SUBSCRIPTION`
- **Subscription IDs for scanning**: Comma-separated list of subscription IDs to monitor
  - Example: `12345678-1234-1234-1234-123456789012,87654321-4321-4321-4321-210987654321`
- **Azure regions**: Comma-separated list of regions where VMs will be scanned
  - Example: `East US,West US,West Europe`
- **Scanning subscription ID**: The subscription where agentless scanning resources will be deployed
  - Example: `12345678-1234-1234-1234-123456789012`
- **Tenant ID**: Your Azure tenant ID (required for authentication)
  - Example: `abcdef12-3456-7890-abcd-ef1234567890`

### Step 4: Generate Terraform Configuration

Generate Terraform configuration using the Lacework CLI:

```bash
lacework generate cloud-account azure \
  --agentless \
  --integration_level <SUBSCRIPTION|TENANT> \
  --agentless_subscription_ids <subscription-ids> \
  --regions <region-list> \
  --subscription_id <scanning-subscription-id>
```

Terraform files are created in `~/lacework/azure` by default.

### Step 5: Authenticate with Azure CLI

```bash
az login --tenant <tenant_id>
az account set --subscription <subscription_id>
```

### Step 6: Deploy with Terraform

Navigate to the generated Terraform directory and deploy:

```bash
cd ~/lacework/azure
terraform init
terraform plan
terraform apply
```

### Step 7: Verify Integration Status

In the Lacework FortiCNAPP console, navigate to **Settings > Integrations > Cloud accounts**. The status of the integration displays as **Success** if all resources are installed correctly.

Reference:
- [lacework generate cloud-account azure](https://docs.fortinet.com/document/forticnapp/latest/cli-reference/635459/lacework-generate-cloud-account-azure)
- [Deploying agentless workload scanning on Azure](https://docs.fortinet.com/document/forticnapp/latest/administration-guide/42109/deploying-agentless-workload-scanning-on-azure)

## How It Works

### Azure Process
1. Container App jobs are scheduled to check for scanning requirements
2. Jobs enumerate monitored subscriptions and identify VMs that need scanning
3. Azure APIs clone VM disks
4. Virtual Machines are launched to mount and scan the cloned disks
5. Cloned disks are analyzed for vulnerabilities within the Azure subscription, then deleted after scanning
6. Scan results (metadata) are stored in Storage Account within the Azure subscription
7. Lacework retrieves scan results via Service Principal with read-only Storage Account access
8. Container App jobs require outbound internet connectivity to Lacework APIs for configuration updates, diagnostic reporting, and on-demand scan requests


## Deployment Details

### Architecture
- Uses Container App Jobs for scheduled scanning tasks
- Uses Virtual Machines to mount and scan cloned disks
- Disk cloning: Azure clones VM disks for scanning

### Terraform Module
- Terraform module: https://registry.terraform.io/modules/lacework/agentless-scanning/azure/latest

### Documentation
- Deployment: https://docs.fortinet.com/document/forticnapp/latest/administration-guide/42109/deploying-agentless-workload-scanning-on-azure
- Integration: https://docs.fortinet.com/document/forticnapp/latest/administration-guide/729300/integrating-your-azure-environment

### Terraform Deployment

#### Resources Provisioned

**Global Resources (deployed once per integration):**
- Azure AD Application and Service Principal for authentication and authorization
- Role Assignments: service principal assigned necessary roles (e.g., Reader, Key Vault Reader) at subscription or management group level
- Resource Group: dedicated resource group for scanning resources

**Regional Resources (deployed per region):**
- Container App Environment: hosts Container App jobs
- Container App Jobs: scheduled scanning tasks
- Virtual Machines: mount and scan cloned disks
- Storage Account: stores snapshots and scan data
- Virtual Network and Subnet: network connectivity for scanning resources
- Network Security Groups: controls network traffic
- Managed Identity: enables Container App jobs to access Azure resources

#### Deployment Scenarios

- Tenant-level (single or multiple regions)
- Subscription-level (single or multiple regions)

#### Optional Inputs

- **Custom VNet**: Use an existing virtual network and subnet instead of creating new ones
- **NAT Gateway**: Configure a NAT gateway to avoid provisioning a large number of public IPs. Recommended for scanning more than 1000 workloads per region to reduce costs
- **Other options**: See [Optional Inputs](https://registry.terraform.io/modules/lacework/agentless-scanning/azure/latest) in the Terraform module documentation

### IAM Permissions

#### Permissions Required for Deployment

The Terraform module requires Azure permissions to deploy the scanning infrastructure. These are permissions required to deploy the integration, not permissions required by the agentless scanning resources. Terraform provisions the roles needed by scanning resources during deployment.

**Tenant-level integration:**

Configure permissions for both the scanning subscription and monitored subscriptions:

- **Scanning subscription**: Define a custom role on a management group containing the scanning subscription with permissions for resource groups, role assignments, managed identities, Key Vault, Storage Accounts, Network Security Groups, Operational Insights, Virtual Networks, Container App managed environments, Container App jobs, and public IP addresses/NAT gateways.

- **Monitored subscription**: Define a custom role on a management group containing all monitored subscriptions with permissions for role definitions and role assignments (read, write, delete).

**Subscription-level integration:**

Configure permissions for the monitored subscription only. Define a custom role with the same permissions as the scanning subscription above.

If using a service principal to run Terraform, grant the following API permission in Entra ID:
- `Microsoft.Graph/Application.ReadWrite.OwnedBy`

Reference: https://docs.fortinet.com/document/forticnapp/latest/administration-guide/991151/preparing-for-integration

#### Permissions Used During Workload Scanning

The scanning process uses a Service Principal with the following Azure RBAC roles:

**Service Principal Roles:**
- Reader Role: read-only access to Azure resources for enumerating and monitoring resources
- Storage Blob Data Reader Role: read access to Azure Blob Storage for accessing VM disk images stored as VHD files

**Role Assignment Scope:**
- Roles are assigned at subscription or management group level
- Service Principal is created during Terraform deployment

**Additional Permissions:**
- `Microsoft.Compute/virtualMachines/read`: read virtual machine configurations
- `Microsoft.Storage/storageAccounts/listKeys/action`: access storage account keys for data retrieval
- `Microsoft.Resources/subscriptions/resourceGroups/read`: read resource group information
- `Microsoft.Network/networkInterfaces/read`: access network interface details

Reference: https://docs.fortinet.com/document/forticnapp/latest/administration-guide/991151/preparing-for-integration

## Resources

- [FortiCNAPP Documentation](https://docs.fortinet.com/document/forticnapp/latest/administration-guide/966589/agentless-workload-scanning)
- [Terraform Registry - Azure Module](https://registry.terraform.io/modules/lacework/agentless-scanning/azure/latest)
- [Agentless Workload Scanning FAQs](https://docs.fortinet.com/document/forticnapp/latest/administration-guide/269317/agentless-workload-scanning-faqs)
