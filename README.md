# NetApp Cloud Services Demo-Infrastrutcture in Azure

This little script creates NetApp Cloud Services in Azure. It will deploy Azure NetApp Files, Cloud Volumes ONTAP and Global File Cache.

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
        
## Cleanup Ressources
At the end of the script there ist a disabled cleanup section. You can enable it or copy, paste and run in Powershell this:

Get-AzResourceGroup -Name *Demo-ANF* | Remove-AzResourceGroup -Force


## Open things and toDo´s
- In the ANF spoke Network I want to deploy a LinuxVM including to integrate the nfs share
- I want to use a whole script-logging wit ouput at the end of the script
