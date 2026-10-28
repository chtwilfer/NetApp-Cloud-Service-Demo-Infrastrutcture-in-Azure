# NetApp Cloud Services Demo Infrastructure in Azure

This repository contains the original deployment script, a safer v2 baseline, and the current v3 script. Use [NCSDemoInfra-v3.ps1](NCSDemoInfra-v3.ps1) for new demo deployments. The original [NCSDemoInfra.ps1](NCSDemoInfra.ps1) and [NCSDemoInfra-v2.ps1](NCSDemoInfra-v2.ps1) remain unchanged for reference.

## What v3 creates

- **West Europe hub:** Hub VNet, Bastion Standard with native tunneling enabled, Windows Server 2025 VM `WinDC01`, and a new AD DS forest named `anfdemo.intra`.
- **North Europe spoke:** Spoke VNet with a delegated Azure NetApp Files subnet and a separate `LinuxClientSubnet` (`10.3.1.0/24`).
- **Ubuntu NFS client:** Ubuntu Server 24.04 VM `UbuntuNfs01`, XFCE desktop, xrdp, a private NIC, and an inbound NSG limited to Bastion and the NFSv3 service ports from the delegated ANF subnet.
- **Azure NetApp Files:** Standard 4 TiB capacity pools and 100 GiB NFSv3 volumes in both regions, plus a snapshot for the West Europe volume.
- **Automatic share mount:** The North Europe volume permits Unix read/write from `10.3.1.0/24` with root access disabled. v3 discovers the volume mount-target IP, mounts it at `/mnt/anf-demo`, and adds a persistent `/etc/fstab` entry.
- **Optional network preparation:** `-deployONTAP` and `-deployGFC` create additional VNets and peerings only. CVO and GFC still require separate deployment through NetApp Cloud Manager.

The Windows Server 2025 image applies to new demo deployments only. v3 does not migrate an existing Windows Server 2019 domain controller. The script creates new resource groups and stops if a target group already exists; it does not clean up resources automatically.

## Prerequisites

- Windows PowerShell 5.1 or later and the Az.Accounts, Az.Resources, Az.Network, Az.Compute and Az.NetAppFiles modules.
- Azure authentication and Azure RBAC permissions for the requested resources. Local Windows administrator rights are not required solely for Azure deployment.
- Azure NetApp Files registered and available in West Europe and North Europe, with sufficient quota/capacity and any required provider features registered.
- The configured VM sizes and Marketplace images available to the selected subscription. v3 checks the Windows Server 2025 image, Ubuntu image and VM sizes at runtime; quota and regional capacity can still prevent deployment.
- Azure CLI with the Bastion extension for the graphical desktop tunnel. Bastion Standard has a higher ongoing cost than Basic.

## Preview and deploy

Run these commands from the repository root. Start with `-WhatIf`; it prints the planned resource actions and exits before Azure login or resource changes:

```powershell
.\NCSDemoInfra-v3.ps1 -CustomerName "ANF-Demo" -SubscriptionId "<subscription-guid>" -WhatIf
```

Deploy the base hub/spoke demo:

```powershell
.\NCSDemoInfra-v3.ps1 -CustomerName "ANF-Demo" -SubscriptionId "<subscription-guid>"
```

Add the CVO and/or GFC network preparation when needed:

```powershell
.\NCSDemoInfra-v3.ps1 -CustomerName "ANF-Demo" -SubscriptionId "<subscription-guid>" -deployONTAP -deployGFC
```

The script prompts separately for the Windows VM administrator, DSRM, and Ubuntu login credentials. Do not reuse the VM administrator and DSRM passwords. The Linux login is used for SSH and the XFCE RDP session. The script does not install or update PowerShell modules, change the execution policy, or deploy CVO/GFC.

Review the subscription and all resource names before allowing the deployment. Bastion Standard and ANF capacity pools incur ongoing charges. A failure partway through can leave resources behind; inspect the exact resource groups before retrying.

## Connect to the Ubuntu desktop

The Ubuntu VM has no public IP. From a workstation with Azure CLI signed in to the same subscription, install/update the Bastion extension if needed and open a tunnel:

```powershell
az login
az account set --subscription "<subscription-guid>"
az extension add --name bastion
$linuxVmId = az vm show --resource-group "ANF-Demo-Demo-ANF-Spoke" --name "UbuntuNfs01" --query id --output tsv
az network bastion tunnel --name "BastionHost" --resource-group "ANF-Demo-Demo-ANF-Hub" --target-resource-id $linuxVmId --resource-port 3389 --port 53389
```

Keep the tunnel command running, then connect with a local RDP client to `localhost:53389` using the Ubuntu username/password entered during deployment. To use the Linux shell instead, connect through Bastion SSH to port 22. Bastion's native-client tunnel requires Standard SKU or higher and tunneling enabled.

After the extension completes, verify the mounted share from the Linux shell:

```bash
findmnt /mnt/anf-demo
df -h /mnt/anf-demo
```

The mount is persistent across reboots. The configuration mounts the North Europe NFSv3 volume only; it does not mount the West Europe volume.

## Terraform status

The [`infra/`](infra/README.md) folder still represents the previous v2 design: it uses the Windows Server 2019 image and does not include the Ubuntu desktop/NFS client. **Do not use that Terraform folder to deploy the v3 design yet.** The Terraform conversion is the next step after v3 is reviewed and tested; it will then be updated to match v3.

## Cleanup

No script deletes resources. Demo teardown is intentional, but resource-group deletion removes every resource and any data within it. First confirm the subscription and inspect each exact group, then preview each deletion individually:

```powershell
Get-AzResourceGroup -Name "ANF-Demo-Demo-ANF-Hub"
Remove-AzResourceGroup -Name "ANF-Demo-Demo-ANF-Hub" -WhatIf
```

Repeat for the exact Spoke and optional resource group names. Do not use wildcard deletion. Only remove a group after reviewing the preview and confirming the demo is disposable.

## Validation status

- v3 PowerShell parser: passed.
- v3 `-WhatIf` with both optional networks: passed; no Azure sign-in or writes occurred.
- No Azure deployment has been run. Desktop login, ANF mount behavior, image/SKU availability and quota require validation in a non-production subscription.

## References

- [Azure Bastion native client and tunnel](https://learn.microsoft.com/en-us/azure/bastion/connect-vm-native-client-windows)
- [Mount Azure NetApp Files NFS volumes on Linux](https://learn.microsoft.com/en-us/azure/azure-netapp-files/azure-netapp-files-mount-unmount-volumes-for-virtual-machines)
- [Azure PowerShell: create a Linux VM](https://learn.microsoft.com/en-us/azure/virtual-machines/linux/quick-create-powershell)
- [Azure PowerShell: create a Windows VM](https://learn.microsoft.com/en-us/azure/virtual-machines/windows/quick-create-powershell)
