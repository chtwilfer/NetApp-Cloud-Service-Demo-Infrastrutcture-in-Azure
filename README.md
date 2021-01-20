### NetApp Cloud Service Demo-Infrastrutcture in Azure

This little script creates NetApp Cloud Services in Azure. It will deploy Azure NetApp Files, Cloud Volumes ONTAP and Global File Cache.

I used the Hub & Spoke Network Deployment for Azure NetApp Files.



## Example
You can start the script with Powershell and Admin rights.

        For the ground deployment ANF with two regions and volumes (Hub & Spoke) use:
        .\ANFDemo.ps1 -CustomerName "ANF-Demo" e.g. -> ANF-Demo

        Use this, if you want to deploy ONTAP in Azure ontop to Hub & Spoke use:
        .\ANFDemo.ps1 -CustomerName "ANF-Demo" -deployONTAP

        Use this, if you want to deploy Global File Cache ontop to Hub & Spoke in Azure use:
        .\ANFDemo.ps1 -CustomerName "ANF-Demo" -deployGFC
        
        Use this, if you want to deploy Global File Cache ontop to Hub & Spoke and ONATP and GFC in Azure use:
        .\ANFDemo.ps1 -CustomerName "ANF-Demo" -deployONTAP -deployGFC        

        During the Script there will be open some webpages for the rest of deploying the whole Demo-Infrastructure.
        
## Cleanup Ressources
At the end of the script there ist a disabled clenup section. You can enable it or copy, paste and run in Powershell:

Get-AzResourceGroup -Name *Demo-ANF* | Remove-AzResourceGroup -Force


## Open things and toDo´s
- In the ANF spoke Network I want to deploy a LinuxVM including to integrate the nfs share
- I want to use a whole script-logging wit ouput at the end of the script
