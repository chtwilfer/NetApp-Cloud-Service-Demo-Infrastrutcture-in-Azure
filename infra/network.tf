locals {
  optional_networks = merge(
    var.deploy_ontap_network ? {
      ontap = {
        resource_group_name = local.resource_group_names.ontap
        location            = var.hub_location
        vnet_name           = "Spoke-VNet-ONTAP"
        address_space       = "10.4.0.0/16"
        subnet_name         = "ONTAP-Subnet"
        subnet_prefix       = "10.4.2.0/24"
        peering_prefix      = "VnetWEToVnetWEONTAP"
      }
    } : {},
    var.deploy_gfc_network ? {
      gfc = {
        resource_group_name = local.resource_group_names.gfc
        location            = var.hub_location
        vnet_name           = "Spoke-VNet-GFC"
        address_space       = "10.5.0.0/16"
        subnet_name         = "GFC-Subnet"
        subnet_prefix       = "10.5.2.0/24"
        peering_prefix      = "VnetWEToVnetWEGFC"
      }
    } : {}
  )

  resource_groups = merge(
    {
      hub = {
        name     = local.resource_group_names.hub
        location = var.hub_location
      }
      spoke = {
        name     = local.resource_group_names.spoke
        location = var.spoke_location
      }
    },
    {
      for key, network in local.optional_networks : key => {
        name     = network.resource_group_name
        location = network.location
      }
    }
  )

  virtual_networks = merge(
    {
      hub = {
        resource_group_key = "hub"
        name               = "Hub-VNet"
        location           = var.hub_location
        address_space      = ["10.2.0.0/16"]
        subnets = {
          bastion = {
            name           = "AzureBastionSubnet"
            address_prefix = "10.2.2.0/26"
            netapp         = false
          }
          domain = {
            name           = "DomainServicesSubnet"
            address_prefix = "10.2.1.0/24"
            netapp         = false
          }
          anf = {
            name           = "anf-${local.customer_token}-subnet-we"
            address_prefix = "10.2.5.0/24"
            netapp         = true
          }
        }
      }
      spoke = {
        resource_group_key = "spoke"
        name               = "Spoke-VNet"
        location           = var.spoke_location
        address_space      = ["10.3.0.0/16"]
        subnets = {
          anf = {
            name           = "anf-${local.customer_token}-subnet-ne"
            address_prefix = "10.3.5.0/24"
            netapp         = true
          }
        }
      }
    },
    {
      for key, network in local.optional_networks : key => {
        resource_group_key = key
        name               = network.vnet_name
        location           = network.location
        address_space      = [network.address_space]
        subnets = {
          workload = {
            name           = network.subnet_name
            address_prefix = network.subnet_prefix
            netapp         = false
          }
        }
      }
    }
  )

  subnets = merge([
    for vnet_key, vnet in local.virtual_networks : {
      for subnet_key, subnet in vnet.subnets : "${vnet_key}.${subnet_key}" => {
        vnet_key       = vnet_key
        name           = subnet.name
        address_prefix = subnet.address_prefix
        netapp         = subnet.netapp
      }
    }
  ]...)

  peering_pairs = merge(
    {
      hub_spoke = {
        left_vnet  = "hub"
        right_vnet = "spoke"
        left_name  = "VnetWEToVnetNE"
        right_name = "VnetNEToVnetWE"
      }
    },
    {
      for key, network in local.optional_networks : key => {
        left_vnet  = "hub"
        right_vnet = key
        left_name  = network.peering_prefix
        right_name = "${network.peering_prefix}Reverse"
      }
    }
  )

  peerings = merge([
    for pair_key, pair in local.peering_pairs : {
      "${pair_key}_forward" = {
        name             = pair.left_name
        local_vnet_key   = pair.left_vnet
        remote_vnet_key  = pair.right_vnet
      }
      "${pair_key}_reverse" = {
        name             = pair.right_name
        local_vnet_key   = pair.right_vnet
        remote_vnet_key  = pair.left_vnet
      }
    }
  ]...)
}

resource "azurerm_resource_group" "this" {
  for_each = local.resource_groups

  name     = each.value.name
  location = each.value.location
  tags     = local.common_tags
}

resource "azurerm_virtual_network" "this" {
  for_each = local.virtual_networks

  name                = each.value.name
  location            = each.value.location
  resource_group_name = azurerm_resource_group.this[each.value.resource_group_key].name
  address_space       = each.value.address_space
  tags                = local.common_tags
}

resource "azurerm_subnet" "this" {
  for_each = local.subnets

  name                 = each.value.name
  resource_group_name  = azurerm_resource_group.this[local.virtual_networks[each.value.vnet_key].resource_group_key].name
  virtual_network_name = azurerm_virtual_network.this[each.value.vnet_key].name
  address_prefixes     = [each.value.address_prefix]

  dynamic "delegation" {
    for_each = each.value.netapp ? [true] : []

    content {
      name = "netapp-delegation"

      service_delegation {
        name = "Microsoft.NetApp/volumes"
        actions = [
          "Microsoft.Network/networkinterfaces/*",
          "Microsoft.Network/virtualNetworks/subnets/join/action"
        ]
      }
    }
  }
}

resource "azurerm_public_ip" "bastion" {
  name                = "Bastion-PIP"
  location            = azurerm_resource_group.this["hub"].location
  resource_group_name = azurerm_resource_group.this["hub"].name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.common_tags
}

resource "azurerm_bastion_host" "hub" {
  name                = "BastionHost"
  location            = azurerm_resource_group.this["hub"].location
  resource_group_name = azurerm_resource_group.this["hub"].name
  sku                 = "Basic"
  tags                = local.common_tags

  ip_configuration {
    name                 = "configuration"
    subnet_id            = azurerm_subnet.this["hub.bastion"].id
    public_ip_address_id = azurerm_public_ip.bastion.id
  }
}

resource "azurerm_virtual_network_peering" "this" {
  for_each = local.peerings

  name                         = each.value.name
  resource_group_name          = azurerm_resource_group.this[local.virtual_networks[each.value.local_vnet_key].resource_group_key].name
  virtual_network_name         = azurerm_virtual_network.this[each.value.local_vnet_key].name
  remote_virtual_network_id    = azurerm_virtual_network.this[each.value.remote_vnet_key].id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
  allow_gateway_transit        = false
  use_remote_gateways          = false
}
