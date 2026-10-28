output "resource_group_names" {
  description = "Resource groups created by this configuration."
  value       = { for key, group in azurerm_resource_group.this : key => group.name }
}

output "virtual_network_ids" {
  description = "Virtual network IDs for the hub, ANF spoke, and any optional networks."
  value       = { for key, vnet in azurerm_virtual_network.this : key => vnet.id }
}

output "domain_controller_private_ip" {
  description = "Private IP address assigned to the Windows domain controller."
  value       = azurerm_network_interface.domain_controller.private_ip_address
}

output "netapp_volume_ids" {
  description = "Azure NetApp Files volume resource IDs by region."
  value       = { for key, volume in azurerm_netapp_volume.this : key => volume.id }
}
