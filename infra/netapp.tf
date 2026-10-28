locals {
  anf_regions = {
    west_europe = {
      location          = var.hub_location
      resource_group    = "hub"
      vnet_key          = "hub"
      account_name      = "anf${local.customer_token}we"
      pool_name         = "anf-${local.customer_token}-pool-we"
      volume_name       = "anf-${local.customer_token}-nfs-we"
      volume_path       = "myfilepath1"
      subnet_key        = "hub.anf"
      allowed_clients   = null
      create_snapshot   = true
    }
    north_europe = {
      location          = var.spoke_location
      resource_group    = "spoke"
      vnet_key          = "spoke"
      account_name      = "anf${local.customer_token}ne"
      pool_name         = "anf-${local.customer_token}-pool-ne"
      volume_name       = "anf-${local.customer_token}-nfs-ne"
      volume_path       = "myfilepath2"
      subnet_key        = "spoke.anf"
      allowed_clients   = ["10.3.1.0/24"]
      create_snapshot   = false
    }
  }
}

resource "azurerm_netapp_account" "this" {
  for_each = local.anf_regions

  name                = each.value.account_name
  location            = each.value.location
  resource_group_name = azurerm_resource_group.this[each.value.resource_group].name
  tags                = local.common_tags
}

resource "azurerm_netapp_pool" "this" {
  for_each = local.anf_regions

  name                = each.value.pool_name
  location            = each.value.location
  resource_group_name = azurerm_resource_group.this[each.value.resource_group].name
  account_name        = azurerm_netapp_account.this[each.key].name
  service_level       = "Standard"
  size_in_tb          = 4
  tags                = local.common_tags
}

resource "azurerm_netapp_volume" "this" {
  for_each = local.anf_regions

  name                = each.value.volume_name
  location            = each.value.location
  resource_group_name = azurerm_resource_group.this[each.value.resource_group].name
  account_name        = azurerm_netapp_account.this[each.key].name
  pool_name           = azurerm_netapp_pool.this[each.key].name
  volume_path         = each.value.volume_path
  service_level       = "Standard"
  subnet_id           = azurerm_subnet.this[each.value.subnet_key].id
  storage_quota_in_gb = 100
  protocols           = ["NFSv3"]
  tags                = local.common_tags

  dynamic "export_policy_rule" {
    for_each = each.value.allowed_clients == null ? [] : [each.value.allowed_clients]

    content {
      rule_index          = 1
      allowed_clients     = export_policy_rule.value
      protocol            = "NFSv3"
      unix_read_write     = true
      root_access_enabled = false
    }
  }
}

resource "azurerm_netapp_snapshot" "west_europe" {
  count = local.anf_regions.west_europe.create_snapshot ? 1 : 0

  name                = "Snapshot-Backup"
  resource_group_name = azurerm_resource_group.this["hub"].name
  account_name        = azurerm_netapp_account.this["west_europe"].name
  pool_name           = azurerm_netapp_pool.this["west_europe"].name
  volume_name         = azurerm_netapp_volume.this["west_europe"].name
  location            = var.hub_location
}
