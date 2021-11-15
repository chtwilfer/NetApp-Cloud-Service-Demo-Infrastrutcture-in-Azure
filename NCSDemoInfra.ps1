<#
	.SYNOPSIS
        Create NetApp Cloud Services in Azure - Demo Infrastructure - (Azure NetApp Files / Cloud Volumes ONTAP / Global File Cache)


	.DESCRIPTION
	Declare your variables accordingly.
	Log in to your public Azure Subscription.
        Make sure that your subscription is ready fro ANF (https://docs.microsoft.com/en-us/azure/azure-netapp-files/azure-netapp-files-register)
        Install Azure Modules - if nessecary
        Look for Provider Feature Registration is nessecary -> the section is diabled
        Cleanup Ressource -> section at the end of this script is disabled

        This script deploys many resources for the Demo-Infrastructure. 
        Here is a short description:
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

        Alternative (ontop):
        - Cloud Volumes ONTAP in North Europe; deployment with Cloud Manager
        - Global File Cache and Cloud Volumes ONTAP in West Europe; Deployment with Cloud Manager
 
        Steps after the script:
        - For ontop deployment use cloud manager to deploy Cloud Volumes ONTAP
        - For ontop deployment use cloud manager to deploy Global Files Cache
        - for SMB share use the webpage


        .REQUIREMENTS
        - Connector for NetApp Cloud Manager to Microsoft Azure
                https://docs.netapp.com/us-en/occm/task_creating_connectors_azure.html#setting-up-azure-permissions-to-create-a-connector
        - NetApp Login to lauch Cloud Manager
        - Azure Subscription
        - Azure Subscription registered with Azure NetApp Files & div. Features
                https://docs.microsoft.com/en-us/azure/azure-netapp-files/azure-netapp-files-register
        

        .EXAMPLE
        You can start the script with Powershell and Admin rights.

        For the ground deployment ANF with two regions and volumes (Hub & Spoke)
        .\NCSDemoInfra.ps1 -CustomerName "ANF-Demo" e.g. -> ANF-Demo

        Use this, if you want to deploy ONTAP in Azure ontop to Hub & Spoke
        .\NCSDemoInfra.ps1 -CustomerName "ANF-Demo" -deployONTAP

        Use this, if you want to deploy Global File Cache ontop to Hub & Spoke in Azure
        .\NCSDemoInfra.ps1 -CustomerName "ANF-Demo" -deployGFC
        
        Use this, if you want to deploy Global File Cache ontop to Hub & Spoke and ONATP and GFC in Azure
        .\NCSDemoInfra.ps1 -CustomerName "ANF-Demo" -deployONTAP -deployGFC        

        During the Script there will be open some webpages for the rest of deploying the whole Demo-Infrastructure.
        

	.NOTES
	    Version:	1.2
	    Author: 	Christian Twilfer (christian.twilfer@outlook.de)
	
	Creation Date: 29.05.2020
        Purpose / Changes:

        V 0.2   20.08.2020 - Register Provider Feature ANF SnapshotPolicy for Subscription - if neccessary
                20.08.2020 - Install-Module -Name Az -AllowClobber -Scope CurrentUser
                20.08.2020 - Update Azure NetApp & Azure Modules - if neccessary
        V 0.3   31.08.2020 - Register Provider Feature ANF Tier Change for Subscription - if neccessary
                31.08.2020 - Check if Provider Feature are registered, if not -> register
                31.08.2020 - region / endregion sections enabled
        V 0.4   14.09.2020 - Parameter changes
        V 0.5   15.09.2020 - Second Location with Parameters / Variables etc. 
                15.09.2020 - Start-Sleep for Oneclick-Deployment
                15.09.2020 - Add Snapshot for Volumes in Region 1
        V 0.6   17.09.2020 - Add Snapshot for Volumes in Region 2
        V 0.7   08.01.2021 - Renew whole Script
                           - Change Script for one Parameter: Cusotmer Name
        V 0.8   11.01.2021 - Windows VM Deployment in Hub network
        V 0.9   13.01.2021 - Change for a full Demo Infrastructure in Azure with Hub & Spoke netwerk, including AD Domain Services (on Windows VM) for SMB volumes                   
        V 1.0   14.01.2021 - new Skipping blocks / section -> [switch] Parameter
                           - Register Provider Feature ANFAesEncryption / ANF BackupOperator / ANFLDAPSigning for Subscription - if neccessary 
        V 1.1   15.01.2021 - DSC Config Domain Controller
                           - Add NFS VolumeSnapshot in Hub Network
        V 1.2   19.01.2021 - Cleanup / Delete all Ressources
                           - VNet Peering Hub & Spoke Network
                           - Config Switch ONTAP Resources
                           - Config Switch GFC Resources
       
                           
        .PARAMETER
        $CustomerName = Customer Name


        .Variables
        There are different variables for the deployment
        Look in #region - #endregion sections / blocks
        

        .todo´s /even open
        - new block for all variables in the script after the parameters section
        - Linux VM in North Europe with username/password, plus connect to nfs share
        - logging the whole script with output at the end
#>

#region put in Parameters
param(

        [Parameter(Mandatory = $True)] # Customername
        [string] $CustomerName,

        #For deployment of ONTAP in a different region
        [switch] $deployONTAP,

        #For deployment of Global File Cache in a different region
        [Switch] $deployGFC
)
#endregion

write-host "Installation of Azure Modules..."

Set-ExecutionPolicy unrestricted -force

#region - Install Azure Modules
        #Install or Update Azure NetApp & Azure Modules - if neccessary
        if ($PSVersionTable.PSEdition -eq 'Desktop' -and (Get-Module -Name AzureRM -ListAvailable)) {
                Write-Warning -Message ('Az module not installed. Having both the AzureRM and ' +
                        'Az modules installed at the same time is not supported.')
        }
        else {
                Install-Module -Name Az -AllowClobber -Force
        }
        Import-Module -Name Az
#endregion

write-host "Connecting to Azure..."
     
#region - Login to Azure, Subscription and register Provider, if neccessary
        #Login to Azure and selct your subscription where you want to deploy ANF
        Connect-AzAccount

        #Subscription
        #List all Subscriptions in Azure and grab your SubscriptionID
        Write-Host "Connecting to Azure Subscription."
        Get-AzSubscription | Where-Object -Property State -eq "Enabled" | Out-Gridview -PassThru | Select-AzSubscription

#endregion

<#region - Feature registration
        #Feature Registration for first time deployment in Azure, after that you can disabel this section
        if ((Get-AzProviderFeature -ProviderNamespace Microsoft.NetApp -FeatureName ANFSnapshotPolicy).RegistrationState -ne "Registered") {
            Register-AzProviderFeature -ProviderNamespace Microsoft.NetApp -FeatureName ANFSnapshotPolicy
        }
        if ((Get-AzProviderFeature -ProviderNamespace Microsoft.NetApp -FeatureName ANFTierChange).RegistrationState -ne "Registered") {
            Register-AzProviderFeature -ProviderNamespace Microsoft.NetApp -FeatureName ANFTierChange
        }
        if ((Get-AzProviderFeature -ProviderNamespace Microsoft.NetApp -FeatureName ANFAesEncryption).RegistrationState -ne "Registered") {
        Register-AzProviderFeature -ProviderNamespace Microsoft.NetApp -FeatureName ANFAesEncryption
        }
        if ((Get-AzProviderFeature -ProviderNamespace Microsoft.NetApp -FeatureName ANFLdapSigning).RegistrationState -ne "Registered") {
         Register-AzProviderFeature -ProviderNamespace Microsoft.NetApp -FeatureName ANFLdapSigning
        }
        if ((Get-AzProviderFeature -ProviderNamespace Microsoft.NetApp -FeatureName ANFBackupOperator).RegistrationState -ne "Registered") {
        Register-AzProviderFeature -ProviderNamespace Microsoft.NetApp -FeatureName ANFBackupOperator
        }

        #Wait for registration to complete
        while ((Get-AzProviderFeature -ProviderNamespace Microsoft.NetApp -FeatureName ANFSnapshotPolicy).RegistrationState -ne "Registered") {
        Start-Sleep -Seconds 10
        }
        while ((Get-AzProviderFeature -ProviderNamespace Microsoft.NetApp -FeatureName ANFTierChange).RegistrationState -ne "Registered") {
        Start-Sleep -Seconds 10
        }
        while ((Get-AzProviderFeature -ProviderNamespace Microsoft.NetApp -FeatureName ANFAesEncryption).RegistrationState -ne "Registered") {
        Start-Sleep -Seconds 10
        }
        while ((Get-AzProviderFeature -ProviderNamespace Microsoft.NetApp -FeatureName ANFLdapSigning).RegistrationState -ne "Registered") {
        Start-Sleep -Seconds 10
        }
        while ((Get-AzProviderFeature -ProviderNamespace Microsoft.NetApp -FeatureName ANFBackupOperator).RegistrationState -ne "Registered") {
        Start-Sleep -Seconds 10
        }
#endregion
#>
     
#region Variables Hub Network
        #First Location (West Europe)
        $location = "westeurope"
        $ResourceGroup = ($CustomerName + "-Demo-ANF-Hub")
        $VirtualNetworkName = "Hub-VNet"
#endregion

#region Variables Spoke Network
        #Second Location (North Europe)
        $secondlocation = "northeurope"
        $secondResourceGroup = ($CustomerName + "-Demo-ANF-Spoke")
        $secondVirtualNetworkName = "Spoke-VNet"
#endregion

write-host "Deploying Hub Network and Ressources..."

#region Create Hub Network and other Hub Ressources
        #First Location - Create a Resource Group
        New-AzResourceGroup -Name $resourceGroup -Location $location
        
        #Create Virtual Networks & Subnets for the Bastian Host
        $subnetBastian = New-AzVirtualNetworkSubnetConfig -Name "AzureBastionSubnet" -AddressPrefix "10.2.2.0/27"
        $vnetBastion = New-AzVirtualNetwork -Name $VirtualNetworkName -ResourceGroupName $resourceGroup -location $location -AddressPrefix "10.2.0.0/16" -Subnet $subnetBastian      
        $publicip = New-AzPublicIpAddress -ResourceGroupName $resourceGroup -name "Bastian-PIP" -location $location -AllocationMethod Static -Sku Standard

        #Create Bastian Host
        New-AzBastion -ResourceGroupName $resourceGroup -Name "BastionHost" -PublicIpAddress $publicip -VirtualNetwork $VnetBastion

        #Create Subnet for Windows Domain Controller
        $cred = Get-Credential -Message "Enter a username and password for the virtual machine."
        $vnetDC = Get-AzVirtualNetwork -Name $VirtualNetworkName -ResourceGroupName $ResourceGroup
        Add-AzVirtualNetworkSubnetConfig -Name "DomainServicesSubnet" -AddressPrefix "10.2.1.0/24" -VirtualNetwork $VnetDC
        $vnetDC | Set-AzVirtualNetwork
        $vnetDC = Get-AzVirtualNetwork -Name $VirtualNetworkName -ResourceGroupName $ResourceGroup
        $nic = New-AzNetworkInterface -Name "WinDC01Nic" -ResourceGroupName $resourceGroup -location $location -SubnetId $vnetDC.Subnets[1].Id
        $vmConfig = New-AzVMConfig -VMName "WinDC01" -VMSize Standard_D2_v3 | Set-AzVMOperatingSystem -Windows -ComputerName "WinDC01" -Credential $cred | Set-AzVMSourceImage -PublisherName MicrosoftWindowsServer -Offer WindowsServer -Skus 2019-Datacenter -Version latest | Add-AzVMNetworkInterface -Id $nic.Id
        
        #Create Windows Domain Controller
        New-AzVM -ResourceGroupName $resourceGroup -location $location -VM $vmConfig
#endregion

#region Config Domain Controller 
$DCInstallScript = 
@'
$logDirectory = "C:\logs"
New-Item -ItemType Directory -Path $logDirectory -Force
Start-Transcript -Path "$logDirectory\ADDS.log"
Import-Module servermanager
Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools
$DSRestorePW = ConvertTo-SecureString -String '#password#' -AsPlainText -Force
Import-Module activedirectory
$ForestParams = @{
CreateDnsDelegation = $false
DomainName = "#domain#"
NoRebootOnCompletion = $true
SafeModeAdministratorPassword = $DSRestorePW
Force = $true
Verbose = $true
}
Install-ADDSForest @ForestParams
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -name "fDenyTSConnections" -Value 0
Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
Stop-Transcript
#Schedule Reboot
Start-Sleep -Seconds 60
Restart-Computer -ComputerName . -Force 
'@

$ADForestName = "anfdemo.intra"

$DCInstallScript = $DCInstallScript -replace '#domain#', $ADForestName
#$DSRestorePW = New-RandomPassword -Length 12
$DCInstallScript = $DCInstallScript -replace '#password#', $cred.GetNetworkCredential().Password

$encoded = [System.Text.Encoding]::Unicode.GetBytes($DCInstallScript)
$etext = [System.Convert]::ToBase64String($encoded)

$ProtectedSettings = '{{"commandToExecute":"powershell -ExecutionPolicy Unrestricted -EncodedCommand {0}"}}' -f $etext

Set-AzVMExtension -ResourceGroupName $resourceGroup -ExtensionName AD-Setup -VMName = "WinDC01" -Publisher Microsoft.Compute -ExtensionType CustomScriptExtension -TypeHandlerVersion 1.10 -ProtectedSettingString $ProtectedSettings -Location $location
#endregion


#region Azure NetApp Files Variables
        #First Location (West Europe)
        $anfAccountName = ($CustomerName + "-ANF-Account-WE")
        $poolName = ($anfAccountName + "-pool-WE")
        $VirtualANFSubnetName = ($anfAccountName + "-ANF-subnet-WE")
        $volumeName = ($anfAccountName + "-NFS-volume-WE")
        $serviceLevel = "Standard"
        $Protocol = "NFSv3"
        $CreationToken = "myfilepath1"
        $SubnetAddressPrefix = "10.2.5.0/24"
#endregion

#region Create ANF Ressources in West Europe 
        #First Location      
        #NetApp Account creation
        New-AzNetAppFilesAccount -ResourceGroupName $resourceGroup -Location $location -Name $anfAccountName
        
        #Create a capacity pool
        $poolSizeBytes = 4398046511104 # 4TiB - firmly defined
        New-AzNetAppFilesPool -ResourceGroupName $resourceGroup -Location $location -AccountName $anfAccountName -Name $poolName -PoolSize $poolSizeBytes -ServiceLevel $serviceLevel
        
        #Create volume (NFSv3) with VNet & Subnet (include subnet delegation)
        $anfDelegation = New-AzDelegation -Name ([guid]::NewGuid().Guid) -ServiceName "Microsoft.NetApp/volumes"
        $vnetANF = Get-AzVirtualNetwork -Name $VirtualNetworkName -ResourceGroupName $ResourceGroup
        Add-AzVirtualNetworkSubnetConfig -Name $VirtualANFSubnetName -AddressPrefix $SubnetAddressPrefix -Delegation $anfDelegation -VirtualNetwork $VnetANF
        $vnetANF | Set-AzVirtualNetwork
        $vnetANF = Get-AzVirtualNetwork -Name $VirtualNetworkName -ResourceGroupName $ResourceGroup
        $subnetId = $vnetANF.Subnets[2].Id
        $volumeSizeBytes = 107374182400 # 100GiB - firmly defined
        
        #Create NFS Volume
        New-AzNetAppFilesVolume -ResourceGroupName $resourceGroup -Location $location -AccountName $anfAccountName -PoolName $poolName -UsageThreshold $volumeSizeBytes -SubnetId $subnetId -CreationToken $CreationToken -ServiceLevel $serviceLevel -Name $volumeName -ProtocolType $Protocol
        
        #Add Snapshot from ANF NFS Volume
        #Get FilSystemID from Volume
        $FileSystemID = Get-AzNetAppFilesVolume -ResourceGroupName $ResourceGroup -AccountName $anfAccountName -PoolName $poolName -VolumeName $volumeName
        # Create a new snapshot from specified volume Region 1
        New-AzNetAppFilesSnapshot -ResourceGroupName $ResourceGroup -location $location -AccountName $anfAccountName -PoolName $poolname -VolumeName $volumename -SnapshotName "Snapshot-Backup" -FileSystemId $FileSystemID.FileSystemID
#endregion

#region Variables Spoke Network
        #Second Location (North Europe)
        $SecondanfAccountName = ($CustomerName + "-ANF-Account-NE")
        $SecondpoolName = ($SecondanfAccountName + "-pool-NE")
        $SecondVirtualNetworkName = "Spoke-VNet"
        $SecondVirtualANFSubnetName = ($SecondanfAccountName + "-ANF-subnet-NE")
        $SecondvolumeName = ($SecondanfAccountName + "-NFS-volume-NE")
        $SecondserviceLevel = "Standard"
        $SecondProtocol = "NFSv3"
        $SecondCreationToken = "myfilepath2"
        $SecondNetworkAddressPrefix = "10.3.0.0/16"
        $SecondSubnetAddressPrefix = "10.3.5.0/24"
#endregion

write-host "Deploying Ressources for ANF in North Europe..."

#region Create Spoke Network and Ressources in North Europe
        #Second Location - Create a Resource Group
        New-AzResourceGroup -Name $secondresourceGroup -Location $secondlocation
        #Create Virtual Network
        New-AzVirtualNetwork -Name $secondVirtualNetworkName -ResourceGroupName $secondresourceGroup -Location $secondlocation -AddressPrefix $secondNetworkAddressPrefix #-Subnet $secondsubnetANF
#endregion
        
#region Create ANF Ressources in North Europe       
        #NetApp Account creation
        New-AzNetAppFilesAccount -ResourceGroupName $secondresourceGroup -Location $secondlocation -Name $secondanfAccountName

        #Create a capacity pool
        $secondpoolSizeBytes = 4398046511104 # 4TiB - firmly defined
        New-AzNetAppFilesPool -ResourceGroupName $secondresourceGroup -Location $secondlocation -AccountName $secondanfAccountName -Name $secondpoolName -PoolSize $secondpoolSizeBytes -ServiceLevel $secondserviceLevel

        #Create volume (NFSv3) with VNet & Subnet (include subnet delegation)
        $secondanfDelegation = New-AzDelegation -Name ([guid]::NewGuid().Guid) -ServiceName "Microsoft.NetApp/volumes"
        $secondvnetANF = Get-AzVirtualNetwork -Name $secondVirtualNetworkName -ResourceGroupName $secondResourceGroup
        Add-AzVirtualNetworkSubnetConfig -Name $secondVirtualANFSubnetName -AddressPrefix $secondSubnetAddressPrefix -Delegation $secondanfDelegation -VirtualNetwork $secondVnetANF
        $secondvnetANF | Set-AzVirtualNetwork
        $secondvnetANF = Get-AzVirtualNetwork -Name $secondVirtualNetworkName -ResourceGroupName $secondResourceGroup
        $secondsubnetId = $secondvnetanf.Subnets[0].Id
        $secondvolumeSizeBytes = 107374182400 # 100GiB - firmly defined

        #Create NFS Volume
        New-AzNetAppFilesVolume -ResourceGroupName $secondresourceGroup -Location $secondlocation -AccountName $secondanfAccountName -PoolName $secondpoolName -UsageThreshold $secondvolumeSizeBytes -SubnetId $secondsubnetId -CreationToken $secondCreationToken -ServiceLevel $secondserviceLevel -Name $secondvolumeName -ProtocolType $secondprotocol
#endregion

#region VNet Peering  first and second location
        #Create peer from first to second and second to first location
        # Get virtual network WE.
        $vnetWE = Get-AzVirtualNetwork -ResourceGroupName $resourceGroup -Name "Hub-VNet"
        $vnetWE | Set-AzVirtualNetwork
        # Get virtual network NE.
        $vnetNE = Get-AzVirtualNetwork -ResourceGroupName $secondresourceGroup -Name "Spoke-VNet"
        $vnetNE | Set-AzVirtualNetwork
        # Peer VNetWE to VNetNE.
        Add-AzVirtualNetworkPeering -Name 'VnetWEToVnetNE' -VirtualNetwork $vnetWE -RemoteVirtualNetworkId $vnetNE.Id
        # Peer VNetNE to VNetWE.
        Add-AzVirtualNetworkPeering -Name 'VnetNEToVnetWE' -VirtualNetwork $VNetNE -RemoteVirtualNetworkId $vnetWE.Id
#endregion


if ($deployONTAP) {
        #Create ONTAP Ressources in West Europe  
        #Variables Spoke Network for ONTAP
        $thirdlocation = "westeurope"
        $thirdResourceGroup = ($CustomerName + "-Demo-ANF-Spoke-ONTAP")
        $thirdVirtualNetworkName = "Spoke-VNet-ONTAP"
        
        #Create a Resource Group
        New-AzResourceGroup -Name $thirdresourceGroup -Location $thirdlocation

        #Create Virtual Networks & Subnets
        $subnetONTAP = New-AzVirtualNetworkSubnetConfig -Name $thirdVirtualNetworkName -AddressPrefix "10.4.2.0/24"
        New-AzVirtualNetwork -Name $thirdVirtualNetworkName -ResourceGroupName $thirdresourceGroup -location $thirdlocation -AddressPrefix "10.4.0.0/16" -Subnet $subnetONTAP

        #Create Virtual Network Peering Hub to ONTAP
        # Get virtual network WE.
        $vnetWE = Get-AzVirtualNetwork -ResourceGroupName $resourceGroup -Name $VirtualNetworkName
        $vnetWE | Set-AzVirtualNetwork
        # Get virtual network NE.
        $vnetONTAP = Get-AzVirtualNetwork -ResourceGroupName $thirdresourceGroup -Name $thirdVirtualNetworkName
        $vnetONTAP | Set-AzVirtualNetwork
        # Peer VNetWE to VNetONTAP
        Add-AzVirtualNetworkPeering -Name 'VnetWEToVnetWEONTAP' -VirtualNetwork $vnetWE -RemoteVirtualNetworkId $vnetONTAP.Id
        # Peer VNetONTAP to VNetWE.
        Add-AzVirtualNetworkPeering -Name 'VnetWEONTAPToVnetWE' -VirtualNetwork $vnetONTAP -RemoteVirtualNetworkId $vnetWE.Id


        write-host "With NetApp´s Cloud Manager you can now deploy an Cloud Volumes ONTAP in Azure!. With Cloud Manager you can now deploy CVO in your Azure Subscription to the Resource Group $thirdResourceGroup and the Virtual Network $thirdVirtualNetworkName."
        
        start-process "https://cloudmanager.netapp.com"
        start-process "https://docs.netapp.com/us-en/occm/task_creating_connectors_azure.html"
}

else {
        Write-Host "You don´t want to deploy ONTAP!"
}

if ($deployGFC) {
        #Create GFC and CVO Ressources in West Europe  
        #Variables Spoke Network for GFC
        $fourthlocation = "westeurope"
        $fourthResourceGroup = ($CustomerName + "-Demo-ANF-Spoke-GFC")
        $fourthVirtualNetworkName = "Spoke-VNet-GFC"
        
        #Create a Resource Group
        New-AzResourceGroup -Name $fourthresourceGroup -Location $fourthlocation

        #Create Virtual Networks & Subnets
        $subnetGFC = New-AzVirtualNetworkSubnetConfig -Name $fourthVirtualNetworkName -AddressPrefix "10.5.2.0/24"
        New-AzVirtualNetwork -Name $fourthVirtualNetworkName -ResourceGroupName $fourthresourceGroup -location $fourthlocation -AddressPrefix "10.5.0.0/16" -Subnet $subnetGFC

        #Create Virtual Network Peering Hub to GFC
        # Get virtual network WE.
        $vnetWE = Get-AzVirtualNetwork -ResourceGroupName $resourceGroup -Name $VirtualNetworkName
        $vnetWE | Set-AzVirtualNetwork
        # Get virtual network NE.
        $vnetGFC = Get-AzVirtualNetwork -ResourceGroupName $fourthresourceGroup -Name $fourthVirtualNetworkName
        $vnetGFC | Set-AzVirtualNetwork
        # Peer VNetWE to VNetGFC.
        Add-AzVirtualNetworkPeering -Name 'VnetWEToVnetWEGFC' -VirtualNetwork $vnetWE -RemoteVirtualNetworkId $vnetGFC.Id
        # Peer VNetGFC to VNetWE.
        Add-AzVirtualNetworkPeering -Name 'VnetWEGFCToVnetWE' -VirtualNetwork $vnetGFC -RemoteVirtualNetworkId $vnetWE.Id


        write-host "With NetApp´s Cloud Manager you can now deploy Cloud Volumes ONTAP and Global File Cache.  With Cloud Manager you can now deploy CVO in your Azure Subscription to the Resource Group $fourthResourceGroup and the Virtual Network $fourthVirtualNetworkName."
        
        start-process "https://cloudmanager.netapp.com"
        start-process "https://docs.netapp.com/us-en/occm/task_gfc_getting_started.html#enable-global-file-cache-in-your-working-environment"
        start-process "https://docs.netapp.com/us-en/occm/task_creating_connectors_azure.html"
}

else {
        Write-Host "You don´t want to deploy Cloud Volumes ONTAP & GFC!"
}

read-host "Press ENTER for deployment ending and open webpage for configuring Active Directory Services on the Dmain Controller........!"

start-process "https://docs.microsoft.com/de-de/azure/azure-netapp-files/azure-netapp-files-create-volumes-smb#active-directory-domain-services"



#region - Cleanup ressources
        #Delete ResourceGroups with all ressources in there
        # Get-AzResourceGroup -Name *Demo-ANF* | Remove-AzResourceGroup -Force

#endregion
