# NetApp Cloud Services Demo-Infrastrutcture in Azure

This little script creates NetApp Cloud Services in Azure. It will help you to deploy Azure NetApp Files, Cloud Volumes ONTAP and Global File Cache.

I used the Hub & Spoke Network Deployment for Azure NetApp Files.

## What is created?
        West Europe (Hub Network)
                - Windows Domain Controller with ADDS
                - VNet with three Subnets (Bastian, Domain, ANF)
                - 1 ANF Account
                - 1 ANF Pool
                - 1 NFS volume
                - Snapshot from NFS volume as a Backup
        
        North Europe (First Spoke Network)
                - VNet with one Subnets (ANF)
                - 1 ANF Account
                - 1 ANF Pool
                - 1 NFS volume
        
        VNet Peering between Hub & Spoke Network and the third & fourth Vnet (ontop)
        
        West Europe ONTAP (ontop)
                - VNet
                - Vnet Peering with Hub Network
        
        West Europe GFC (ontop)
                - VNet
                - Vnet Peering with Hub Network

For configuring ONTAP and GFC you can use the NetApp Cloud Manager. 
Requirements:
- Connector for NetApp Cloud Manager to Microsoft Azure - https://docs.netapp.com/us-en/occm/task_creating_connectors_azure.html#setting-up-azure-permissions-to-create-a-connector
- NetApp Login to lauch Cloud Manager

## Feature Registration and enablement ANF for the subscription
Make sure that your subscription is ready fro ANF - https://docs.microsoft.com/en-us/azure/azure-netapp-files/azure-netapp-files-register

There are some Azure NetApp Provider Features, that have to enabled at the first time you use it.
There is a disabled section in the script after connecting to Azure and getting your subscription.
For using enable it.

## Example for using the script
You can start the script with Powershell and Admin rights.

        For the ground deployment ANF with two regions and volumes (Hub & Spoke) use:
        .\NCSDemoInfra.ps1 -CustomerName "ANF-Demo" e.g. -> ANF-Demo

        Use this, if you want to deploy ONTAP in Azure ontop to Hub & Spoke use:
        .\NCSDemoInfra.ps1 -CustomerName "ANF-Demo" -deployONTAP

        Use this, if you want to deploy Global File Cache ontop to Hub & Spoke in Azure use:
        .\NCSDemoInfra.ps1 -CustomerName "ANF-Demo" -deployGFC
        
        Use this, if you want to deploy Global File Cache ontop to Hub & Spoke and ONATP and GFC in Azure use:
        .\NCSDemoInfra.ps1 -CustomerName "ANF-Demo" -deployONTAP -deployGFC        

        During the Script there will be open some webpages for the rest of deploying the whole Demo-Infrastructure.

## Improved script
`NCSDemoInfra-v2.ps1` is the safer replacement path; the original `NCSDemoInfra.ps1` remains unchanged. It requires the Azure Subscription ID and does not install modules or change the execution policy.

Preview the planned resources without signing in or changing Azure:

```powershell
.\NCSDemoInfra-v2.ps1 -CustomerName "ANF-Demo" -SubscriptionId "00000000-0000-0000-0000-000000000000" -WhatIf
```

Deploy the base Hub-and-Spoke setup:

```powershell
.\NCSDemoInfra-v2.ps1 -CustomerName "ANF-Demo" -SubscriptionId "<subscription-guid>"
```

Append `-deployONTAP` and/or `-deployGFC` to prepare those networks for a separate NetApp Cloud Manager deployment. These switches do not deploy CVO or GFC. Use `-OpenGuidance` to open the relevant documentation after a successful run.

The new script requires the Az.Accounts, Az.Resources, Az.Network, Az.Compute and Az.NetAppFiles modules, plus Azure permissions for the requested resources. It creates new resource groups only and stops if any target resource group already exists. Confirm Azure NetApp Files region availability, quota, provider features and pricing before deployment. Windows local administrator rights are not inherently required; Azure RBAC permissions are.

## Terraform conversion
The Terraform conversion is in the [`infra/`](infra/README.md) folder. It includes the root configuration, Azure networking and peering, Bastion, Windows domain controller/AD DS extension, Azure NetApp Files volumes and the optional CVO/GFC network preparation. Follow that folder's instructions to configure remote state, validate and review a plan. The configuration does not run `terraform apply` automatically.
        
## Cleanup Ressources
Neither script deletes resources automatically. Do not use wildcard deletion for demo cleanup. First inspect each exact resource group name, then preview deletion individually with `Remove-AzResourceGroup -Name '<exact-resource-group-name>' -WhatIf`. Remove resources only after confirming the subscription, resource group contents and expected deletion.


## Open things and toDo´s
- In the ANF spoke Network I want to deploy a LinuxVM including to integrate the nfs share
- Validate the new deployment script against a non-production Azure subscription and confirm current ANF quotas and regional availability
