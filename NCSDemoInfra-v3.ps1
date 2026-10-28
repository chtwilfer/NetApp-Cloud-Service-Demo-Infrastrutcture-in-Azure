#requires -Version 5.1
<#
.SYNOPSIS
    Erstellt die Demo-Infrastruktur mit Azure NetApp Files und Linux-NFS-Client.

.DESCRIPTION
    Erstellt die Netzwerke, Bastion Standard mit Tunnel-Unterstuetzung, einen
    Windows Server 2025 Domain Controller, eine Ubuntu-24.04-Desktop-VM und
    Azure NetApp Files Accounts, Pools, NFS-Volumes und optional einen Snapshot.
    Die Ubuntu-VM erhaelt XFCE/xrdp und mountet das North-Europe-NFSv3-Volume
    persistent unter /mnt/anf-demo.
    Die Schalter -deployONTAP und -deployGFC bereiten jeweils nur ein VNet und
    Peering fuer eine nachgelagerte Bereitstellung mit NetApp Cloud Manager vor.

    Dieses Skript erstellt ausschliesslich neue Demo-Resource-Groups. Sind
    Zielgruppen bereits vorhanden, wird vor dem ersten Deployment-Schritt
    abgebrochen. Es gibt keinen automatischen Cleanup.

.PARAMETER CustomerName
    Kundenpraefix fuer Resource Groups und Ressourcennamen.

.PARAMETER SubscriptionId
    Eindeutige Azure Subscription-ID. Eine interaktive Subscription-Auswahl
    wird absichtlich nicht verwendet.

.PARAMETER deployONTAP
    Bereitet das Netzwerk fuer eine separate Cloud Volumes ONTAP-Bereitstellung
    in West Europe vor. CVO wird nicht von diesem Skript installiert.

.PARAMETER deployGFC
    Bereitet das Netzwerk fuer eine separate Global File Cache-Bereitstellung
    in West Europe vor. GFC wird nicht von diesem Skript installiert.

.PARAMETER OpenGuidance
    Oeffnet nach erfolgreichem Deployment die passenden Cloud-Manager- und
    Dokumentationsseiten.

.EXAMPLE
    .\NCSDemoInfra-v3.ps1 -CustomerName 'ANF-Demo' -SubscriptionId '00000000-0000-0000-0000-000000000000' -WhatIf

.EXAMPLE
    .\NCSDemoInfra-v3.ps1 -CustomerName 'ANF-Demo' -SubscriptionId '00000000-0000-0000-0000-000000000000' -deployONTAP -deployGFC

.NOTES
    Erfordert die Az-Teilmodule Az.Accounts, Az.Resources, Az.Network,
    Az.Compute und Az.NetAppFiles. Das Skript installiert oder aktualisiert
    keine Module und aendert keine Execution Policy.

    Vor dem produktiven Einsatz muessen Azure NetApp Files-Region, Quota und
    Provider-/Feature-Voraussetzungen fuer die Subscription bestaetigt werden.
    Das DSRM-Kennwort wird separat abgefragt. Es wird fuer die VM-Extension
    lokal temporaer in eine Befehlszeichenfolge eingesetzt und als geschuetzte
    Extension-Einstellung an Azure uebergeben; Base64 selbst ist keine
    Verschluesselung. Die Werte werden nicht in die Skript-Logdatei geschrieben.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38}[A-Za-z0-9])?$')]
    [string] $CustomerName,

    [Parameter(Mandatory = $true)]
    [guid] $SubscriptionId,

    [switch] $deployONTAP,

    [switch] $deployGFC,

    [switch] $OpenGuidance,

    [string] $LogDirectory = (Join-Path $PSScriptRoot 'logs')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LogFile = $null

function Write-DeploymentLog {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Message,

        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string] $Level = 'INFO'
    )

    $entry = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $entry
    if ($script:LogFile) {
        Add-Content -LiteralPath $script:LogFile -Value $entry -Encoding UTF8
    }
}

function Invoke-AzMutation {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Target,

        [Parameter(Mandatory = $true)]
        [string] $Action,

        [Parameter(Mandatory = $true)]
        [scriptblock] $Operation
    )

    if ($PSCmdlet.ShouldProcess($Target, $Action)) {
        & $Operation
    }
    elseif (-not $WhatIfPreference) {
        throw "Aktion '$Action' fuer '$Target' wurde nicht bestaetigt. Deployment wird abgebrochen."
    }
}

function Get-IPv4Range {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Cidr
    )

    if ($Cidr -notmatch '^([0-9]{1,3}(?:\.[0-9]{1,3}){3})/([0-9]{1,2})$') {
        throw "Ungueltiges IPv4-CIDR-Praefix: $Cidr"
    }

    $address = [System.Net.IPAddress]::Parse($Matches[1])
    if ($address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        throw "Es wird ein IPv4-Praefix erwartet: $Cidr"
    }

    $prefixLength = [int] $Matches[2]
    if ($prefixLength -lt 0 -or $prefixLength -gt 32) {
        throw "Ungueltige Praefixlaenge in '$Cidr'."
    }

    $octets = $address.GetAddressBytes()
    foreach ($octet in $octets) {
        if ($octet -gt 255) {
            throw "Ungueltige IPv4-Adresse in '$Cidr'."
        }
    }

    $addressValue = [uint64]($octets[0] * 16777216 + $octets[1] * 65536 + $octets[2] * 256 + $octets[3])
    $blockSize = [uint64][Math]::Pow(2, 32 - $prefixLength)
    $networkStart = [uint64]([Math]::Floor($addressValue / $blockSize) * $blockSize)

    [pscustomobject]@{
        Cidr  = $Cidr
        Start = $networkStart
        End   = ($networkStart + $blockSize - 1)
    }
}

function Assert-NoOverlappingCidrs {
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Cidrs
    )

    $ranges = @($Cidrs | ForEach-Object { Get-IPv4Range -Cidr $_ })
    for ($leftIndex = 0; $leftIndex -lt $ranges.Count; $leftIndex++) {
        for ($rightIndex = $leftIndex + 1; $rightIndex -lt $ranges.Count; $rightIndex++) {
            $leftRange = $ranges[$leftIndex]
            $rightRange = $ranges[$rightIndex]
            if ($leftRange.Start -le $rightRange.End -and $rightRange.Start -le $leftRange.End) {
                throw "Adressbereiche '$($leftRange.Cidr)' und '$($rightRange.Cidr)' ueberlappen sich."
            }
        }
    }
}

function Assert-SubnetInsideVnet {
    param(
        [Parameter(Mandatory = $true)]
        [string] $VnetPrefix,

        [Parameter(Mandatory = $true)]
        [string[]] $SubnetPrefixes
    )

    $vnetRange = Get-IPv4Range -Cidr $VnetPrefix
    foreach ($prefix in $SubnetPrefixes) {
        $subnetRange = Get-IPv4Range -Cidr $prefix
        if ($subnetRange.Start -lt $vnetRange.Start -or $subnetRange.End -gt $vnetRange.End) {
            throw "Subnetz '$prefix' liegt nicht vollstaendig innerhalb des VNet-Praefixes '$VnetPrefix'."
        }
    }
    Assert-NoOverlappingCidrs -Cidrs $SubnetPrefixes
}

function Invoke-NewResourceGroup {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [string] $Location
    )

    Invoke-AzMutation -Target "Resource Group '$Name'" -Action 'neu erstellen' -Operation {
        New-AzResourceGroup -Name $Name -Location $Location -ErrorAction Stop
    }
}

function New-DemoVnet {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [string] $ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string] $Location,

        [Parameter(Mandatory = $true)]
        [string] $AddressPrefix,

        [Parameter(Mandatory = $true)]
        [object[]] $SubnetDefinitions
    )

    $subnetConfigs = foreach ($subnet in $SubnetDefinitions) {
        if ($subnet.Delegated) {
            $delegation = New-AzDelegation -Name ("{0}-{1}-delegation" -f $Name, $subnet.Name) -ServiceName 'Microsoft.NetApp/volumes'
            New-AzVirtualNetworkSubnetConfig -Name $subnet.Name -AddressPrefix $subnet.AddressPrefix -Delegation $delegation
        }
        else {
            New-AzVirtualNetworkSubnetConfig -Name $subnet.Name -AddressPrefix $subnet.AddressPrefix
        }
    }

    Invoke-AzMutation -Target "VNet '$Name' in '$ResourceGroupName'" -Action 'mit Subnetzen erstellen' -Operation {
        New-AzVirtualNetwork -Name $Name -ResourceGroupName $ResourceGroupName -Location $Location -AddressPrefix $AddressPrefix -Subnet $subnetConfigs -ErrorAction Stop
    }
}

function Get-SubnetIdByName {
    param(
        [Parameter(Mandatory = $true)]
        [object] $VirtualNetwork,

        [Parameter(Mandatory = $true)]
        [string] $SubnetName
    )

    $subnet = $VirtualNetwork.Subnets | Where-Object { $_.Name -eq $SubnetName } | Select-Object -First 1
    if (-not $subnet) {
        throw "Subnetz '$SubnetName' wurde im VNet '$($VirtualNetwork.Name)' nicht gefunden."
    }
    $subnet.Id
}

function Get-AnfMountTargetIp {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Configuration
    )

    $volume = Get-AzNetAppFilesVolume -ResourceGroupName $Configuration.ResourceGroup -AccountName $Configuration.AccountName -PoolName $Configuration.PoolName -VolumeName $Configuration.VolumeName -ErrorAction Stop
    $mountTargetIp = $null
    $mountTargetsProperty = $volume.PSObject.Properties['MountTargets']
    if ($mountTargetsProperty) {
        $mountTarget = @($mountTargetsProperty.Value | Where-Object { $_.IpAddress } | Select-Object -First 1)
        if ($mountTarget.Count -gt 0) {
            $mountTargetIp = $mountTarget[0].IpAddress
        }
    }

    if ([string]::IsNullOrWhiteSpace($mountTargetIp)) {
        $armPath = "$($volume.Id)?api-version=2025-01-01"
        $armVolume = (Invoke-AzRestMethod -Path $armPath -Method GET -ErrorAction Stop).Content | ConvertFrom-Json
        $mountTarget = @($armVolume.properties.mountTargets | Where-Object { $_.ipAddress } | Select-Object -First 1)
        if ($mountTarget.Count -gt 0) {
            $mountTargetIp = $mountTarget[0].ipAddress
        }
    }

    $parsedIp = $null
    if ([string]::IsNullOrWhiteSpace($mountTargetIp) -or -not [System.Net.IPAddress]::TryParse($mountTargetIp, [ref]$parsedIp)) {
        throw "Mount-Target-IP fuer ANF-Volume '$($Configuration.VolumeName)' konnte nicht ermittelt werden."
    }
    $mountTargetIp
}

function New-AnfRegion {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject] $Configuration,

        [Parameter(Mandatory = $true)]
        [string] $SubnetId
    )

    Write-DeploymentLog "Erstelle Azure NetApp Files in $($Configuration.Location)."

    Invoke-AzMutation -Target "ANF Account '$($Configuration.AccountName)'" -Action 'erstellen' -Operation {
        New-AzNetAppFilesAccount -ResourceGroupName $Configuration.ResourceGroup -Location $Configuration.Location -Name $Configuration.AccountName -ErrorAction Stop
    }

    Invoke-AzMutation -Target "ANF Pool '$($Configuration.PoolName)'" -Action 'mit 4 TiB erstellen' -Operation {
        New-AzNetAppFilesPool -ResourceGroupName $Configuration.ResourceGroup -Location $Configuration.Location -AccountName $Configuration.AccountName -Name $Configuration.PoolName -PoolSize $Configuration.PoolSizeBytes -ServiceLevel $Configuration.ServiceLevel -ErrorAction Stop
    }

    $volumeParameters = @{
        ResourceGroupName = $Configuration.ResourceGroup
        Location          = $Configuration.Location
        AccountName       = $Configuration.AccountName
        PoolName          = $Configuration.PoolName
        UsageThreshold    = $Configuration.VolumeSizeBytes
        SubnetId          = $SubnetId
        CreationToken     = $Configuration.CreationToken
        ServiceLevel      = $Configuration.ServiceLevel
        Name              = $Configuration.VolumeName
        ProtocolType      = $Configuration.ProtocolType
        ErrorAction       = 'Stop'
    }
    if ($Configuration.AllowedClientSubnet) {
        $exportPolicyRule = New-AzNetAppFilesExportPolicyRuleObject -RuleIndex 1 -AllowedClient $Configuration.AllowedClientSubnet -UnixReadWrite -Nfsv3 -ErrorAction Stop
        $exportPolicyRule.HasRootAccess = $false
        $volumeParameters.ExportPolicy = New-AzNetAppFilesExportPolicyObject -Rule @($exportPolicyRule) -ErrorAction Stop
    }

    Invoke-AzMutation -Target "ANF Volume '$($Configuration.VolumeName)'" -Action 'mit 100 GiB NFSv3 erstellen' -Operation {
        New-AzNetAppFilesVolume @volumeParameters
    }

    if ($Configuration.CreateSnapshot) {
        $volume = Get-AzNetAppFilesVolume -ResourceGroupName $Configuration.ResourceGroup -AccountName $Configuration.AccountName -PoolName $Configuration.PoolName -VolumeName $Configuration.VolumeName -ErrorAction Stop
        Invoke-AzMutation -Target "ANF Volume '$($Configuration.VolumeName)'" -Action 'Snapshot-Backup erstellen' -Operation {
            New-AzNetAppFilesSnapshot -ResourceGroupName $Configuration.ResourceGroup -Location $Configuration.Location -AccountName $Configuration.AccountName -PoolName $Configuration.PoolName -VolumeName $Configuration.VolumeName -SnapshotName 'Snapshot-Backup' -FileSystemId $volume.FileSystemId -ErrorAction Stop
        }
    }
}

function New-BidirectionalVnetPeering {
    param(
        [Parameter(Mandatory = $true)]
        [string] $LeftResourceGroup,

        [Parameter(Mandatory = $true)]
        [string] $LeftVnetName,

        [Parameter(Mandatory = $true)]
        [string] $RightResourceGroup,

        [Parameter(Mandatory = $true)]
        [string] $RightVnetName,

        [Parameter(Mandatory = $true)]
        [string] $LeftToRightPeeringName,

        [Parameter(Mandatory = $true)]
        [string] $RightToLeftPeeringName
    )

    $leftVnet = Get-AzVirtualNetwork -ResourceGroupName $LeftResourceGroup -Name $LeftVnetName -ErrorAction Stop
    $rightVnet = Get-AzVirtualNetwork -ResourceGroupName $RightResourceGroup -Name $RightVnetName -ErrorAction Stop

    Invoke-AzMutation -Target "Peering '$LeftToRightPeeringName'" -Action 'erstellen' -Operation {
        Add-AzVirtualNetworkPeering -Name $LeftToRightPeeringName -VirtualNetwork $leftVnet -RemoteVirtualNetworkId $rightVnet.Id -ErrorAction Stop
    }
    Invoke-AzMutation -Target "Peering '$RightToLeftPeeringName'" -Action 'erstellen' -Operation {
        Add-AzVirtualNetworkPeering -Name $RightToLeftPeeringName -VirtualNetwork $rightVnet -RemoteVirtualNetworkId $leftVnet.Id -ErrorAction Stop
    }
}

function Register-NetAppResourceProvider {
    $provider = Get-AzResourceProvider -ProviderNamespace 'Microsoft.NetApp' -ErrorAction Stop
    if ($provider.RegistrationState -eq 'Registered') {
        return
    }

    Write-DeploymentLog 'Microsoft.NetApp ist noch nicht registriert; Registrierung wird angefordert.' 'WARN'
    Invoke-AzMutation -Target 'Provider Microsoft.NetApp' -Action 'registrieren' -Operation {
        Register-AzResourceProvider -ProviderNamespace 'Microsoft.NetApp' -ErrorAction Stop | Out-Null
    }

    $deadline = (Get-Date).AddMinutes(15)
    do {
        Start-Sleep -Seconds 15
        $provider = Get-AzResourceProvider -ProviderNamespace 'Microsoft.NetApp' -ErrorAction Stop
    } while ($provider.RegistrationState -ne 'Registered' -and (Get-Date) -lt $deadline)

    if ($provider.RegistrationState -ne 'Registered') {
        throw 'Microsoft.NetApp wurde innerhalb von 15 Minuten nicht registriert.'
    }
}

$customerToken = ($CustomerName -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
$customerToken = $customerToken.Substring(0, [Math]::Min(12, $customerToken.Length))
$hubResourceGroup = "$CustomerName-Demo-ANF-Hub"
$spokeResourceGroup = "$CustomerName-Demo-ANF-Spoke"
$hubLocation = 'westeurope'
$spokeLocation = 'northeurope'
$hubVnetName = 'Hub-VNet'
$spokeVnetName = 'Spoke-VNet'
$linuxVmName = 'UbuntuNfs01'
$linuxVmSize = 'Standard_D2s_v5'
$linuxImagePublisher = 'Canonical'
$linuxImageOffer = 'ubuntu-24_04-lts'
$linuxImageSku = 'server'
$linuxClientSubnetName = 'LinuxClientSubnet'
$linuxClientSubnetPrefix = '10.3.1.0/24'
$linuxMountPath = '/mnt/anf-demo'

$anfRegions = @(
    [pscustomobject]@{
        Location       = $hubLocation
        ResourceGroup  = $hubResourceGroup
        AccountName    = "anf${customerToken}we"
        PoolName       = "anf-${customerToken}-pool-we"
        VnetName       = $hubVnetName
        VnetPrefix     = '10.2.0.0/16'
        SubnetName     = "anf-${customerToken}-subnet-we"
        SubnetPrefix   = '10.2.5.0/24'
        VolumeName     = "anf-${customerToken}-nfs-we"
        CreationToken  = 'myfilepath1'
        PoolSizeBytes  = [long]4398046511104
        VolumeSizeBytes = [long]107374182400
        ServiceLevel   = 'Standard'
        ProtocolType   = 'NFSv3'
        AllowedClientSubnet = $null
        CreateSnapshot = $true
    },
    [pscustomobject]@{
        Location       = $spokeLocation
        ResourceGroup  = $spokeResourceGroup
        AccountName    = "anf${customerToken}ne"
        PoolName       = "anf-${customerToken}-pool-ne"
        VnetName       = $spokeVnetName
        VnetPrefix     = '10.3.0.0/16'
        SubnetName     = "anf-${customerToken}-subnet-ne"
        SubnetPrefix   = '10.3.5.0/24'
        VolumeName     = "anf-${customerToken}-nfs-ne"
        CreationToken  = 'myfilepath2'
        PoolSizeBytes  = [long]4398046511104
        VolumeSizeBytes = [long]107374182400
        ServiceLevel   = 'Standard'
        ProtocolType   = 'NFSv3'
        AllowedClientSubnet = $linuxClientSubnetPrefix
        CreateSnapshot = $false
    }
)

$optionalNetworks = @()
if ($deployONTAP) {
    $optionalNetworks += [pscustomobject]@{
        ResourceGroup = "$CustomerName-Demo-ANF-Spoke-ONTAP"
        Location      = $hubLocation
        VnetName      = 'Spoke-VNet-ONTAP'
        VnetPrefix    = '10.4.0.0/16'
        SubnetName    = 'ONTAP-Subnet'
        SubnetPrefix  = '10.4.2.0/24'
        PeeringPrefix = 'VnetWEToVnetWEONTAP'
    }
}
if ($deployGFC) {
    $optionalNetworks += [pscustomobject]@{
        ResourceGroup = "$CustomerName-Demo-ANF-Spoke-GFC"
        Location      = $hubLocation
        VnetName      = 'Spoke-VNet-GFC'
        VnetPrefix    = '10.5.0.0/16'
        SubnetName    = 'GFC-Subnet'
        SubnetPrefix  = '10.5.2.0/24'
        PeeringPrefix = 'VnetWEToVnetWEGFC'
    }
}

$hubSubnetPrefixes = @('10.2.2.0/26', '10.2.1.0/24', '10.2.5.0/24')
Assert-NoOverlappingCidrs -Cidrs (@($anfRegions | ForEach-Object { $_.VnetPrefix }) + @($optionalNetworks | ForEach-Object { $_.VnetPrefix }))
Assert-SubnetInsideVnet -VnetPrefix $anfRegions[0].VnetPrefix -SubnetPrefixes $hubSubnetPrefixes
Assert-SubnetInsideVnet -VnetPrefix $anfRegions[1].VnetPrefix -SubnetPrefixes @($anfRegions[1].SubnetPrefix, $linuxClientSubnetPrefix)
foreach ($optionalNetwork in $optionalNetworks) {
    Assert-SubnetInsideVnet -VnetPrefix $optionalNetwork.VnetPrefix -SubnetPrefixes @($optionalNetwork.SubnetPrefix)
}

$plannedResourceGroups = @($hubResourceGroup, $spokeResourceGroup) + @($optionalNetworks | ForEach-Object { $_.ResourceGroup })
$deploymentPlan = [System.Collections.Generic.List[object]]::new()
foreach ($resourceGroupName in $plannedResourceGroups) {
    $deploymentPlan.Add([pscustomobject]@{ Target = "Resource Group '$resourceGroupName'"; Action = 'neu erstellen' })
}
$deploymentPlan.Add([pscustomobject]@{ Target = "VNet '$hubVnetName'"; Action = 'mit Bastion-, Domain- und ANF-Subnetz erstellen' })
$deploymentPlan.Add([pscustomobject]@{ Target = "Bastion in '$hubResourceGroup'"; Action = 'mit Standard-SKU und Tunnel-Unterstuetzung erstellen' })
$deploymentPlan.Add([pscustomobject]@{ Target = "VM 'WinDC01' in '$hubResourceGroup'"; Action = 'mit Windows Server 2025 erstellen und Domain Services konfigurieren' })
$deploymentPlan.Add([pscustomobject]@{ Target = "Subnetz '$linuxClientSubnetName' in '$spokeVnetName'"; Action = 'fuer Ubuntu-NFS-Client erstellen' })
$deploymentPlan.Add([pscustomobject]@{ Target = "NSG 'LinuxClientNsg' in '$spokeResourceGroup'"; Action = 'Bastion-Zugriff und NFSv3-Ports fuer das ANF-Subnetz erlauben' })
$deploymentPlan.Add([pscustomobject]@{ Target = "VM '$linuxVmName' in '$spokeResourceGroup'"; Action = 'mit Ubuntu 24.04, XFCE und xrdp erstellen' })
foreach ($region in $anfRegions) {
    if ($region.VnetName -ne $hubVnetName) {
        $deploymentPlan.Add([pscustomobject]@{ Target = "VNet '$($region.VnetName)'"; Action = "in '$($region.Location)' mit ANF-Subnetz erstellen" })
    }
    $deploymentPlan.Add([pscustomobject]@{ Target = "ANF Account '$($region.AccountName)'"; Action = "in '$($region.Location)' erstellen" })
    $deploymentPlan.Add([pscustomobject]@{ Target = "ANF Pool/Volume '$($region.PoolName)' / '$($region.VolumeName)'"; Action = 'mit 4 TiB / 100 GiB erstellen' })
    if ($region.CreateSnapshot) {
        $deploymentPlan.Add([pscustomobject]@{ Target = "ANF Volume '$($region.VolumeName)'"; Action = 'Snapshot-Backup erstellen' })
    }
}
$deploymentPlan.Add([pscustomobject]@{ Target = "VNet Peering '$hubVnetName' <-> '$spokeVnetName'"; Action = 'bidirektional erstellen' })
foreach ($network in $optionalNetworks) {
    $deploymentPlan.Add([pscustomobject]@{ Target = "VNet '$($network.VnetName)'"; Action = "Netzwerk fuer nachgelagerte Bereitstellung vorbereiten" })
    $deploymentPlan.Add([pscustomobject]@{ Target = "VNet Peering '$hubVnetName' <-> '$($network.VnetName)'"; Action = 'bidirektional erstellen' })
}

if ($WhatIfPreference) {
    foreach ($planItem in $deploymentPlan) {
        $PSCmdlet.ShouldProcess($planItem.Target, $planItem.Action) | Out-Null
    }
    return
}

$vmCredential = $null
$dsrmCredential = $null
$dsrmPassword = $null
$protectedSettings = $null

try {
    if (-not (Test-Path -LiteralPath $LogDirectory)) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    }
    $script:LogFile = Join-Path $LogDirectory ("NCSDemoInfra-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Write-DeploymentLog 'Starte Vorabpruefungen.'

    $requiredModules = @('Az.Accounts', 'Az.Resources', 'Az.Network', 'Az.Compute', 'Az.NetAppFiles')
    foreach ($moduleName in $requiredModules) {
        if (-not (Get-Module -ListAvailable -Name $moduleName)) {
            throw "Modul '$moduleName' fehlt. Installiere es separat, zum Beispiel mit Install-Module -Name '$moduleName' -Scope CurrentUser."
        }
        Import-Module -Name $moduleName -ErrorAction Stop
    }

    Connect-AzAccount -ErrorAction Stop | Out-Null
    $context = Set-AzContext -Subscription $SubscriptionId -ErrorAction Stop
    if ($context.Subscription.Id -ne $SubscriptionId.Guid) {
        throw "Der aktive Azure-Kontext entspricht nicht der angeforderten Subscription '$SubscriptionId'."
    }
    Write-DeploymentLog ("Subscription: {0}; Tenant: {1}" -f $context.Subscription.Id, $context.Tenant.Id)

    foreach ($resourceGroupName in $plannedResourceGroups) {
        $existingResourceGroup = Get-AzResourceGroup -Name $resourceGroupName -ErrorAction SilentlyContinue
        if ($existingResourceGroup) {
            throw "Resource Group '$resourceGroupName' existiert bereits. Dieses Skript erstellt nur neue Demo-Resource-Groups und veraendert vorhandene Gruppen nicht."
        }
    }

    $availableVmSizes = Get-AzVMSize -Location $hubLocation -ErrorAction Stop
    if (-not ($availableVmSizes | Where-Object { $_.Name -eq 'Standard_D2_v3' })) {
        throw "VM-SKU 'Standard_D2_v3' ist in '$hubLocation' nicht verfuegbar."
    }
    $availableLinuxVmSizes = Get-AzVMSize -Location $spokeLocation -ErrorAction Stop
    if (-not ($availableLinuxVmSizes | Where-Object { $_.Name -eq $linuxVmSize })) {
        throw "VM-SKU '$linuxVmSize' ist in '$spokeLocation' nicht verfuegbar."
    }

    $windowsImageSkus = Get-AzVMImageSku -Location $hubLocation -PublisherName 'MicrosoftWindowsServer' -Offer 'WindowsServer' -ErrorAction Stop
    if (-not ($windowsImageSkus | Where-Object { $_.Skus -eq '2025-datacenter' })) {
        throw "Windows Server 2025 Image-SKU '2025-datacenter' ist in '$hubLocation' nicht verfuegbar."
    }
    $ubuntuImageSkus = Get-AzVMImageSku -Location $spokeLocation -PublisherName $linuxImagePublisher -Offer $linuxImageOffer -ErrorAction Stop
    if (-not ($ubuntuImageSkus | Where-Object { $_.Skus -eq $linuxImageSku })) {
        throw "Ubuntu Image '$($linuxImagePublisher):$($linuxImageOffer):$($linuxImageSku)' ist in '$spokeLocation' nicht verfuegbar."
    }
    Write-DeploymentLog "VM-Groessen und Marketplace-Images sind in '$hubLocation' und '$spokeLocation' verfuegbar."
    Write-DeploymentLog 'ANF-Region, verfuegbare Kapazitaet, Quota und ggf. zusaetzliche Provider-Features muessen vor dem Lauf fuer die Subscription bestaetigt sein.' 'WARN'

    Register-NetAppResourceProvider

    $vmCredential = Get-Credential -Message 'Zugangsdaten fuer das lokale Windows-Administratorkonto von WinDC01 eingeben.'
    if ([string]::IsNullOrWhiteSpace($vmCredential.UserName) -or $vmCredential.UserName.Length -gt 20 -or $vmCredential.UserName -match '[\\/@:]') {
        throw 'Der VM-Benutzername ist fuer ein lokales Windows-Administratorkonto ungueltig.'
    }
    $dsrmCredential = Get-Credential -Message 'Ein separates Kennwort fuer den Directory Services Restore Mode (DSRM) eingeben.'
    $dsrmPassword = $dsrmCredential.GetNetworkCredential().Password
    if ([string]::IsNullOrWhiteSpace($dsrmPassword)) {
        throw 'Das DSRM-Kennwort darf nicht leer sein.'
    }
    $linuxVmCredential = Get-Credential -Message 'Linux-Benutzername und Kennwort fuer SSH/xrdp der Ubuntu-VM eingeben.'
    if ($linuxVmCredential.UserName -notmatch '^[a-z_][a-z0-9_-]{0,30}$') {
        throw 'Der Linux-Benutzername muss mit einem Kleinbuchstaben oder Unterstrich beginnen und darf nur Kleinbuchstaben, Ziffern, Unterstriche und Bindestriche enthalten.'
    }
    if ([string]::IsNullOrWhiteSpace($linuxVmCredential.GetNetworkCredential().Password)) {
        throw 'Das Linux-Kennwort darf nicht leer sein.'
    }

    Write-DeploymentLog 'Erstelle Hub-Netzwerk und Bastion.'
    Invoke-NewResourceGroup -Name $hubResourceGroup -Location $hubLocation | Out-Null

    $hubSubnetDefinitions = @(
        [pscustomobject]@{ Name = 'AzureBastionSubnet'; AddressPrefix = '10.2.2.0/26'; Delegated = $false },
        [pscustomobject]@{ Name = 'DomainServicesSubnet'; AddressPrefix = '10.2.1.0/24'; Delegated = $false },
        [pscustomobject]@{ Name = $anfRegions[0].SubnetName; AddressPrefix = $anfRegions[0].SubnetPrefix; Delegated = $true }
    )
    $hubVnet = New-DemoVnet -Name $hubVnetName -ResourceGroupName $hubResourceGroup -Location $hubLocation -AddressPrefix $anfRegions[0].VnetPrefix -SubnetDefinitions $hubSubnetDefinitions
    if (-not $hubVnet) {
        throw 'Hub-VNet wurde nicht erstellt.'
    }

    $publicIp = Invoke-AzMutation -Target "Public IP 'Bastion-PIP' in '$hubResourceGroup'" -Action 'mit Standard-SKU erstellen' -Operation {
        New-AzPublicIpAddress -ResourceGroupName $hubResourceGroup -Name 'Bastion-PIP' -Location $hubLocation -AllocationMethod Static -Sku Standard -ErrorAction Stop
    }
    Invoke-AzMutation -Target "Bastion 'BastionHost' in '$hubResourceGroup'" -Action 'erstellen' -Operation {
        New-AzBastion -ResourceGroupName $hubResourceGroup -Name 'BastionHost' -PublicIpAddress $publicIp -VirtualNetwork $hubVnet -Sku 'Standard' -EnableTunneling $true -ErrorAction Stop
    } | Out-Null

    $domainSubnetId = Get-SubnetIdByName -VirtualNetwork $hubVnet -SubnetName 'DomainServicesSubnet'
    $nic = Invoke-AzMutation -Target "NIC 'WinDC01Nic' in '$hubResourceGroup'" -Action 'erstellen' -Operation {
        New-AzNetworkInterface -Name 'WinDC01Nic' -ResourceGroupName $hubResourceGroup -Location $hubLocation -SubnetId $domainSubnetId -ErrorAction Stop
    }
    $vmConfig = New-AzVMConfig -VMName 'WinDC01' -VMSize 'Standard_D2_v3' |
        Set-AzVMOperatingSystem -Windows -ComputerName 'WinDC01' -Credential $vmCredential |
        Set-AzVMSourceImage -PublisherName 'MicrosoftWindowsServer' -Offer 'WindowsServer' -Skus '2025-datacenter' -Version 'latest' |
        Add-AzVMNetworkInterface -Id $nic.Id
    Invoke-AzMutation -Target "VM 'WinDC01' in '$hubResourceGroup'" -Action 'erstellen' -Operation {
        New-AzVM -ResourceGroupName $hubResourceGroup -Location $hubLocation -VM $vmConfig -ErrorAction Stop
    } | Out-Null

    $dsrmEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($dsrmPassword))
    $domainScript = @'
$logDirectory = 'C:\logs'
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
Start-Transcript -Path (Join-Path $logDirectory 'ADDS.log')
try {
    Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools
    $dsrmText = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('__DSRM_BASE64__'))
    $dsrmPassword = ConvertTo-SecureString -String $dsrmText -AsPlainText -Force
    Import-Module ActiveDirectory
    $forestParameters = @{
        CreateDnsDelegation = $false
        DomainName = 'anfdemo.intra'
        NoRebootOnCompletion = $true
        SafeModeAdministratorPassword = $dsrmPassword
        Force = $true
    }
    Install-ADDSForest @forestParameters
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0
    Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'
}
finally {
    Stop-Transcript
}
Start-Sleep -Seconds 60
Restart-Computer -ComputerName . -Force
'@
    $domainScript = $domainScript.Replace('__DSRM_BASE64__', $dsrmEncoded)
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($domainScript))
    $protectedSettings = @{ commandToExecute = "powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedCommand" } | ConvertTo-Json -Compress

    Invoke-AzMutation -Target "VM 'WinDC01' in '$hubResourceGroup'" -Action 'AD DS Custom Script Extension konfigurieren' -Operation {
        Set-AzVMExtension -ResourceGroupName $hubResourceGroup -ExtensionName 'AD-Setup' -VMName 'WinDC01' -Publisher 'Microsoft.Compute' -ExtensionType 'CustomScriptExtension' -TypeHandlerVersion '1.10' -ProtectedSettingString $protectedSettings -Location $hubLocation -ErrorAction Stop
    } | Out-Null

    $dsrmPassword = $null
    $dsrmCredential = $null
    $protectedSettings = $null
    $domainScript = $null
    $encodedCommand = $null
    $dsrmEncoded = $null

    Write-DeploymentLog 'Erstelle ANF-Spoke in North Europe.'
    Invoke-NewResourceGroup -Name $spokeResourceGroup -Location $spokeLocation | Out-Null
    $spokeSubnetDefinitions = @(
        [pscustomobject]@{ Name = $anfRegions[1].SubnetName; AddressPrefix = $anfRegions[1].SubnetPrefix; Delegated = $true },
        [pscustomobject]@{ Name = $linuxClientSubnetName; AddressPrefix = $linuxClientSubnetPrefix; Delegated = $false }
    )
    $spokeVnet = New-DemoVnet -Name $spokeVnetName -ResourceGroupName $spokeResourceGroup -Location $spokeLocation -AddressPrefix $anfRegions[1].VnetPrefix -SubnetDefinitions $spokeSubnetDefinitions
    if (-not $spokeVnet) {
        throw 'Spoke-VNet wurde nicht erstellt.'
    }

    foreach ($region in $anfRegions) {
        $vnet = if ($region.VnetName -eq $hubVnetName) { $hubVnet } else { $spokeVnet }
        $subnetId = Get-SubnetIdByName -VirtualNetwork $vnet -SubnetName $region.SubnetName
        New-AnfRegion -Configuration $region -SubnetId $subnetId | Out-Null
    }

    $northEuropeAnf = $anfRegions | Where-Object { $_.Location -eq $spokeLocation } | Select-Object -First 1
    $anfMountTargetIp = Get-AnfMountTargetIp -Configuration $northEuropeAnf
    Write-DeploymentLog "ANF-Mount-Target fuer '$($northEuropeAnf.VolumeName)': $anfMountTargetIp"

    Write-DeploymentLog 'Erstelle Ubuntu-Desktop-VM und NFS-Client im Spoke.'
    $linuxNsgRules = @(
        (New-AzNetworkSecurityRuleConfig -Name 'AllowBastionRdp' -Description 'RDP tunnel from Azure Bastion subnet' -Access Allow -Protocol Tcp -Direction Inbound -Priority 100 -SourceAddressPrefix '10.2.2.0/26' -SourcePortRange '*' -DestinationAddressPrefix '*' -DestinationPortRange '3389'),
        (New-AzNetworkSecurityRuleConfig -Name 'AllowBastionSsh' -Description 'SSH from Azure Bastion subnet' -Access Allow -Protocol Tcp -Direction Inbound -Priority 110 -SourceAddressPrefix '10.2.2.0/26' -SourcePortRange '*' -DestinationAddressPrefix '*' -DestinationPortRange '22'),
        (New-AzNetworkSecurityRuleConfig -Name 'AllowAnfNfsTcp' -Description 'NFSv3 and lock-manager traffic from the delegated ANF subnet' -Access Allow -Protocol Tcp -Direction Inbound -Priority 120 -SourceAddressPrefix $anfRegions[1].SubnetPrefix -SourcePortRange '*' -DestinationAddressPrefix '*' -DestinationPortRange @('111', '635', '2049', '4045', '4046')),
        (New-AzNetworkSecurityRuleConfig -Name 'AllowAnfNfsUdp' -Description 'NFSv3 and lock-manager traffic from the delegated ANF subnet' -Access Allow -Protocol Udp -Direction Inbound -Priority 130 -SourceAddressPrefix $anfRegions[1].SubnetPrefix -SourcePortRange '*' -DestinationAddressPrefix '*' -DestinationPortRange @('111', '635', '2049', '4045', '4046')),
        (New-AzNetworkSecurityRuleConfig -Name 'DenyOtherVnetInbound' -Description 'Block other virtual-network initiated inbound traffic' -Access Deny -Protocol '*' -Direction Inbound -Priority 200 -SourceAddressPrefix 'VirtualNetwork' -SourcePortRange '*' -DestinationAddressPrefix '*' -DestinationPortRange '*')
    )
    $linuxNsg = Invoke-AzMutation -Target "NSG 'LinuxClientNsg' in '$spokeResourceGroup'" -Action 'nur fuer Bastion-SSH/RDP freigeben' -Operation {
        New-AzNetworkSecurityGroup -Name 'LinuxClientNsg' -ResourceGroupName $spokeResourceGroup -Location $spokeLocation -SecurityRules $linuxNsgRules -ErrorAction Stop
    }
    $linuxSubnetId = Get-SubnetIdByName -VirtualNetwork $spokeVnet -SubnetName $linuxClientSubnetName
    $linuxNic = Invoke-AzMutation -Target "NIC '${linuxVmName}Nic' in '$spokeResourceGroup'" -Action 'im Linux-Client-Subnetz erstellen' -Operation {
        New-AzNetworkInterface -Name "${linuxVmName}Nic" -ResourceGroupName $spokeResourceGroup -Location $spokeLocation -SubnetId $linuxSubnetId -NetworkSecurityGroupId $linuxNsg.Id -ErrorAction Stop
    }
    $linuxVmConfig = New-AzVMConfig -VMName $linuxVmName -VMSize $linuxVmSize |
        Set-AzVMOperatingSystem -Linux -ComputerName $linuxVmName -Credential $linuxVmCredential |
        Set-AzVMSourceImage -PublisherName $linuxImagePublisher -Offer $linuxImageOffer -Skus $linuxImageSku -Version 'latest' |
        Add-AzVMNetworkInterface -Id $linuxNic.Id
    $linuxVm = Invoke-AzMutation -Target "Ubuntu-VM '$linuxVmName' in '$spokeResourceGroup'" -Action 'ohne Public IP erstellen' -Operation {
        New-AzVM -ResourceGroupName $spokeResourceGroup -Location $spokeLocation -VM $linuxVmConfig -ErrorAction Stop
    }

    $linuxBootstrapTemplate = @'
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

LINUX_USERNAME='__LINUX_USERNAME__'
ANF_MOUNT_TARGET='__ANF_MOUNT_TARGET__'
ANF_VOLUME_PATH='__ANF_VOLUME_PATH__'
MOUNT_PATH='__MOUNT_PATH__'

apt-get update
apt-get install -y xfce4 xfce4-goodies xrdp nfs-common
printf '%s\n' 'startxfce4' > "/home/${LINUX_USERNAME}/.xsession"
chown "${LINUX_USERNAME}:${LINUX_USERNAME}" "/home/${LINUX_USERNAME}/.xsession"
adduser xrdp ssl-cert
systemctl enable --now xrdp

mkdir -p "${MOUNT_PATH}"
mount -t nfs -o rw,hard,noatime,nolock,rsize=65536,wsize=65536,vers=3,tcp "${ANF_MOUNT_TARGET}:/${ANF_VOLUME_PATH}" "${MOUNT_PATH}"
mountpoint -q "${MOUNT_PATH}"

FSTAB_ENTRY="${ANF_MOUNT_TARGET}:/${ANF_VOLUME_PATH} ${MOUNT_PATH} nfs bg,rw,hard,noatime,nolock,rsize=65536,wsize=65536,vers=3,tcp,_netdev,nofail 0 0"
if ! grep -Fqx "${FSTAB_ENTRY}" /etc/fstab; then
    printf '%s\n' "${FSTAB_ENTRY}" >> /etc/fstab
fi
'@
    $linuxBootstrapScript = $linuxBootstrapTemplate.Replace('__LINUX_USERNAME__', $linuxVmCredential.UserName)
    $linuxBootstrapScript = $linuxBootstrapScript.Replace('__ANF_MOUNT_TARGET__', $anfMountTargetIp)
    $linuxBootstrapScript = $linuxBootstrapScript.Replace('__ANF_VOLUME_PATH__', $northEuropeAnf.CreationToken)
    $linuxBootstrapScript = $linuxBootstrapScript.Replace('__MOUNT_PATH__', $linuxMountPath)
    $linuxBootstrapScript = $linuxBootstrapScript.Replace("`r`n", "`n")
    $linuxBootstrapBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($linuxBootstrapScript))
    $linuxSettings = @{
        commandToExecute = "echo $linuxBootstrapBase64 | base64 --decode | bash"
    } | ConvertTo-Json -Compress

    Invoke-AzMutation -Target "Ubuntu-VM '$linuxVmName' in '$spokeResourceGroup'" -Action 'XFCE/xrdp und persistenten ANF-NFSv3-Mount konfigurieren' -Operation {
        Set-AzVMExtension -ResourceGroupName $spokeResourceGroup -VMName $linuxVmName -Name 'LinuxDesktopAndAnfMount' -Publisher 'Microsoft.Azure.Extensions' -ExtensionType 'CustomScript' -TypeHandlerVersion '2.1' -SettingString $linuxSettings -Location $spokeLocation -ErrorAction Stop
    } | Out-Null
    $linuxVmCredential = $null
    $linuxSettings = $null
    $linuxBootstrapScript = $null
    $linuxBootstrapTemplate = $null
    $linuxBootstrapBase64 = $null

    New-BidirectionalVnetPeering -LeftResourceGroup $hubResourceGroup -LeftVnetName $hubVnetName -RightResourceGroup $spokeResourceGroup -RightVnetName $spokeVnetName -LeftToRightPeeringName 'VnetWEToVnetNE' -RightToLeftPeeringName 'VnetNEToVnetWE'

    foreach ($network in $optionalNetworks) {
        Write-DeploymentLog "Bereite Netzwerk fuer nachgelagerte Bereitstellung '$($network.VnetName)' vor."
        Invoke-NewResourceGroup -Name $network.ResourceGroup -Location $network.Location | Out-Null
        $subnetDefinition = [pscustomobject]@{ Name = $network.SubnetName; AddressPrefix = $network.SubnetPrefix; Delegated = $false }
        $optionalVnet = New-DemoVnet -Name $network.VnetName -ResourceGroupName $network.ResourceGroup -Location $network.Location -AddressPrefix $network.VnetPrefix -SubnetDefinitions @($subnetDefinition)
        if (-not $optionalVnet) {
            throw "VNet '$($network.VnetName)' wurde nicht erstellt."
        }
        New-BidirectionalVnetPeering -LeftResourceGroup $hubResourceGroup -LeftVnetName $hubVnetName -RightResourceGroup $network.ResourceGroup -RightVnetName $network.VnetName -LeftToRightPeeringName $network.PeeringPrefix -RightToLeftPeeringName ($network.PeeringPrefix + 'Reverse')
        Write-DeploymentLog "Netzwerk '$($network.VnetName)' ist vorbereitet. CVO/GFC muessen separat mit NetApp Cloud Manager bereitgestellt werden."
    }

    Write-DeploymentLog 'Deployment-Schritte wurden abgeschlossen.'
    Write-DeploymentLog "Resource Groups: $($plannedResourceGroups -join ', ')"
    Write-DeploymentLog "Ubuntu-GUI: Azure Bastion Standard-Tunnel zu ${linuxVmName} auf Port 3389 oeffnen, lokal z.B. Port 53389 verwenden und den RDP-Client mit localhost:53389 verbinden."
    Write-DeploymentLog "ANF-NFSv3 ist unter '$linuxMountPath' eingehangen und in /etc/fstab eingetragen."
    if ($OpenGuidance) {
        Start-Process 'https://cloudmanager.netapp.com'
        Start-Process 'https://docs.netapp.com/us-en/occm/task_creating_connectors_azure.html'
        Start-Process 'https://learn.microsoft.com/azure/azure-netapp-files/configure-active-directory-connections'
        if ($deployGFC) {
            Start-Process 'https://docs.netapp.com/us-en/occm/task_gfc_getting_started.html#enable-global-file-cache-in-your-working-environment'
        }
    }
}
catch {
    if ($script:LogFile) {
        Write-DeploymentLog 'Deployment fehlgeschlagen. Die vollstaendige Fehlermeldung folgt in der PowerShell-Ausgabe.' 'ERROR'
    }
    throw
}
finally {
    $vmCredential = $null
    $dsrmCredential = $null
    $dsrmPassword = $null
    $linuxVmCredential = $null
    $protectedSettings = $null
}
