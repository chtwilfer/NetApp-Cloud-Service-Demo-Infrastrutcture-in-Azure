# Azure NetApp Files Demo Infrastructure (Terraform)

This folder converts the deployment flow from `NCSDemoInfra-v2.ps1` to Terraform. It creates a West Europe hub, Bastion, Windows Server 2019 domain controller with AD DS forest setup, and Azure NetApp Files accounts/pools/NFSv3 volumes in West Europe and North Europe. It also creates a snapshot for the West Europe volume. Optional flags prepare additional VNets and peerings for a separate Cloud Volumes ONTAP and/or Global File Cache deployment; those products are not deployed here.

The Terraform files describe new resource groups. They do not import or manage resources created by running the PowerShell script. Do not apply this configuration to a subscription where those names already exist unless the existing resources have been deliberately imported into Terraform state and reviewed.

## Prerequisites

- Terraform 1.7 or later.
- On Windows, install Terraform with `winget install Hashicorp.Terraform` if it is not already available.
- An Azure subscription and permission to create the listed network, compute, Bastion, and Azure NetApp Files resources.
- The AzureRM Terraform provider is pinned to the current 4.x line.
- Azure authentication configured outside this folder, for example `az login` and `az account set --subscription <subscription-id>`, or an approved workload identity/service principal setup.
- Azure NetApp Files enabled and available in both target regions, with sufficient quota/capacity and any required provider features registered.
- An existing Azure Storage account/container for the remote Terraform state backend. Create and secure it separately; this folder intentionally does not bootstrap its own state backend.

## Configure

Copy `terraform.tfvars.example` to `terraform.tfvars` and set the subscription ID and customer name. The example file has no passwords. Supply credentials through a secret manager or the current PowerShell session instead of committing them:

```powershell
$env:TF_VAR_vm_admin_password = Read-Host 'VM administrator password' -AsSecureString | ForEach-Object { [System.Net.NetworkCredential]::new('', $_).Password }
$env:TF_VAR_dsrm_password = Read-Host 'Separate DSRM password' -AsSecureString | ForEach-Object { [System.Net.NetworkCredential]::new('', $_).Password }
```

The VM and DSRM passwords are separate sensitive inputs. The AD DS extension's protected settings contain the bootstrap command and DSRM secret; Terraform state can therefore contain sensitive data. Use the Azure Blob backend shown in `backend.hcl.example`, restrict access with Azure RBAC, enable storage encryption and versioning, and never commit state, backend credentials or a populated `terraform.tfvars` file. Sensitive variables mask CLI output; they do not prevent state storage.

To prepare backend configuration, copy `backend.hcl.example` to `backend.hcl`, fill in the existing state storage resource group/account/container, and use Microsoft Entra authentication. Do not check in the completed file.

## Validate and deploy

For offline/provider validation without connecting to the backend:

```powershell
terraform init -backend=false
terraform validate
```

For a real plan, initialize the configured remote backend first:

```powershell
terraform init -backend-config=backend.hcl
terraform plan -out=demo.tfplan
terraform show demo.tfplan
```

Review the complete plan, verify the subscription and expected costs, and only then apply the saved plan:

```powershell
terraform apply demo.tfplan
```

No deployment is performed automatically. The Azure Bastion host uses a Standard public IP; the domain controller itself has no public IP. Azure Bastion requires the reserved `AzureBastionSubnet` with a `/26` prefix. The NFS volumes are exposed through their delegated VNets; configure client routing, DNS and access policy separately as required by the demo.

Optional network preparation:

```hcl
deploy_ontap_network = true
deploy_gfc_network   = true
```

These options create only the extra VNets, resource groups and bidirectional peerings. Cloud Volumes ONTAP and Global File Cache require separate provisioning in NetApp Cloud Manager.

## Cleanup

Terraform destroy removes managed resources and can incur data loss and charges. Review `terraform plan -destroy` carefully before any destroy operation. The AzureRM provider is configured to prevent deletion of a resource group while it contains resources. There is no wildcard or automatic cleanup command.

## Provider references

- [AzureRM provider](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs)
- [Virtual network](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/virtual_network)
- [Bastion host](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/bastion_host)
- [Windows virtual machine](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/windows_virtual_machine)
- [Azure NetApp volume](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/netapp_volume)
