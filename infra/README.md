# Azure NetApp Files Demo Infrastructure (Terraform)

This folder converts the deployment flow from `NCSDemoInfra-v2.ps1` to Terraform. It creates:

- A West Europe hub VNet with Bastion, domain-services and delegated ANF subnets.
- An Azure Bastion host and a Windows Server 2019 domain controller VM. A VM extension installs an AD DS forest named `anfdemo.intra`.
- Azure NetApp Files accounts and 4 TiB Standard pools in West Europe and North Europe, each with a 100 GiB NFSv3 volume.
- A `Snapshot-Backup` snapshot for the West Europe volume.
- Optional VNets and bidirectional peerings to prepare for separate Cloud Volumes ONTAP and/or Global File Cache deployments.

The optional networks do not deploy Cloud Volumes ONTAP or Global File Cache. Those products must be provisioned separately through NetApp Cloud Manager.

Terraform manages the resources declared in this folder. It does not import resources created by either PowerShell script. If the target resource groups or resources already exist, do not run `apply` until you have deliberately imported the resources into the correct Terraform state and reviewed the resulting plan.

## 1. Prerequisites

- Terraform 1.7 or later. On Windows, install it with `winget install Hashicorp.Terraform` if needed.
- Azure CLI for interactive authentication, or an approved workload identity/service-principal setup for automation.
- An Azure subscription with permissions to create resource groups, VNets, peering, Bastion, a Windows VM, and Azure NetApp Files resources.
- Azure NetApp Files available in both target regions (`westeurope` and `northeurope`), with sufficient quota/capacity and any required provider features registered.
- A supported Windows VM size in West Europe. The default is `Standard_D2_v3`; verify availability and quota in your subscription before planning.
- An existing Azure Storage account and blob container for remote Terraform state. This project intentionally does not create its own state backend.

The AzureRM provider is constrained to `>= 4.2, < 5.0`. Terraform may generate `.terraform.lock.hcl` on initialization; keep that lock file under version control so subsequent runs use the same provider build.

## 2. Open the Terraform folder

Run the following commands in PowerShell from the repository root:

```powershell
Set-Location .\infra
terraform version
terraform fmt -recursive
```

Review the formatting changes before continuing. All commands below assume the current directory is `infra`.

## 3. Authenticate and select the subscription

For an interactive local run:

```powershell
az login
az account set --subscription "<subscription-id>"
az account show --query "{name:name, id:id, tenantId:tenantId}" --output table
```

Confirm that the displayed subscription is the intended target. Terraform uses `subscription_id` from `terraform.tfvars`; the Azure CLI context supplies authentication. Do not put client secrets in provider configuration.

## 4. Set deployment values and credentials

Copy the example variables file and edit the non-secret settings:

```powershell
Copy-Item .\terraform.tfvars.example .\terraform.tfvars
notepad .\terraform.tfvars
```

Set `subscription_id` and `customer_name`. The optional network switches default to `false`; set either one or both to `true` to create the corresponding VNet and peering. Do not add passwords to `terraform.tfvars`.

For an interactive PowerShell session, enter two distinct passwords as secure input:

```powershell
$secureVmPassword = Read-Host 'VM administrator password' -AsSecureString
$env:TF_VAR_vm_admin_password = [System.Net.NetworkCredential]::new('', $secureVmPassword).Password

$secureDsrmPassword = Read-Host 'Separate DSRM password' -AsSecureString
$env:TF_VAR_dsrm_password = [System.Net.NetworkCredential]::new('', $secureDsrmPassword).Password
```

Both passwords must be at least 12 characters. For automation, use the pipeline's secret store or an approved secret manager to provide the `TF_VAR_*` variables. Clear the session variables after use:

```powershell
Remove-Item Env:TF_VAR_vm_admin_password, Env:TF_VAR_dsrm_password -ErrorAction SilentlyContinue
```

**Protect Terraform state.** The AD DS extension's protected settings contain the bootstrap command and DSRM secret, so Terraform state and saved plan files can contain sensitive data. `sensitive = true` masks normal CLI output; it does not remove values from state. Use remote Azure Blob state, Entra ID authentication, narrowly scoped Azure RBAC, storage encryption and versioning. Never commit `terraform.tfvars`, backend configuration, state files or saved plans.

## 5. Configure remote state

The state storage account and container must exist before initialization. Create them through your organization's approved process and restrict access to the Terraform operators and pipeline identity. Use a dedicated state key for this deployment; do not share the same key with another environment or workspace.

Copy the backend example and replace every placeholder with the existing backend resource details:

```powershell
Copy-Item .\backend.hcl.example .\backend.hcl
notepad .\backend.hcl
```

The example enables Entra-based backend authentication. The identity running Terraform must have the required data-plane access to the state container (typically `Storage Blob Data Contributor`) and management-plane access to deploy the workload. Do not add storage account keys or client secrets to `backend.hcl`.

## 6. Initialize and validate

First run a local validation without configuring or contacting the remote backend:

```powershell
terraform init -backend=false
terraform validate
```

If validation succeeds, initialize the real remote backend:

```powershell
terraform init -backend-config=backend.hcl
terraform validate
```

The first initialization downloads the AzureRM provider and creates or updates `.terraform.lock.hcl`. Do not run `terraform apply` if initialization or validation reports an error.

## 7. Review a deployment plan

Create a saved plan and inspect it before making any Azure changes:

```powershell
terraform plan -out=demo.tfplan
terraform show demo.tfplan
```

Check all of the following in the output:

- The selected subscription and all resource group names are correct.
- The plan creates the intended resources and does not replace or destroy unexpected resources.
- The optional CVO/GFC networks appear only when their variables are `true`.
- ANF quota, region availability and estimated costs are acceptable. Bastion and ANF capacity pools incur ongoing charges.
- No existing PowerShell-created resources are being duplicated or managed accidentally.

Saved plans may contain secrets. Keep `demo.tfplan` local and protected; do not attach it to tickets or commit it.

## 8. Deploy

Only after reviewing the complete saved plan, deploy that exact plan:

```powershell
terraform apply demo.tfplan
```

Terraform prompts for the two sensitive passwords if they were not supplied in environment variables. No resources are created by `terraform init`, `terraform validate`, or `terraform plan`; `terraform apply` is the deployment step.

When deployment completes, inspect the outputs:

```powershell
terraform output
terraform output -json
```

The domain controller has no public IP; connect through Bastion. AD DS setup and the VM restart can take several minutes. The NFS volumes use delegated subnets, but this configuration does not mount them on a client VM or configure the full client routing, export policy, DNS, or SMB/ANF Active Directory integration.

## Optional networks

To prepare both optional networks, set these values in `terraform.tfvars`:

```hcl
deploy_ontap_network = true
deploy_gfc_network   = true
```

Then rerun `terraform plan`, review the changes, and apply the reviewed saved plan. These options create only the additional resource groups, VNets, subnets and peerings. They do not create CVO or GFC resources.

## Update and destroy

For later changes, edit the configuration, then run `terraform fmt -recursive`, `terraform validate`, and `terraform plan -out=demo.tfplan`. Review the plan before applying it.

Destroying this configuration deletes managed infrastructure and can permanently remove data. If cleanup is explicitly intended, first create and review a destroy plan:

```powershell
terraform plan -destroy -out=destroy.tfplan
terraform show destroy.tfplan
```

Only after confirming every deletion and the selected subscription should an operator run:

```powershell
terraform apply destroy.tfplan
```

The AzureRM provider is configured to prevent deleting a resource group while it still contains resources. Resolve any destroy-plan errors deliberately; do not work around the protection with wildcard deletion or an unreviewed force operation.

## Provider references

- [AzureRM provider](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs)
- [Terraform AzureRM backend](https://developer.hashicorp.com/terraform/language/backend/azurerm)
- [Virtual network](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/virtual_network)
- [Bastion host](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/bastion_host)
- [Windows virtual machine](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/windows_virtual_machine)
- [Virtual machine extension](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/virtual_machine_extension)
- [Azure NetApp volume](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/netapp_volume)
