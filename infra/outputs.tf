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

output "linux_nfs_client_private_ip" {
  description = "Private IP address assigned to the Ubuntu desktop/NFS client."
  value       = azurerm_network_interface.linux_client.private_ip_address
}

output "anf_north_europe_mount_target_ip" {
  description = "Azure NetApp Files NFS mount target IP used by the Ubuntu client."
  value       = azurerm_netapp_volume.this["north_europe"].ip_address
}

output "linux_nfs_mount_path" {
  description = "Persistent NFSv3 mount path on the Ubuntu client."
  value       = "/mnt/anf-demo"
}

output "netapp_volume_ids" {
  description = "Azure NetApp Files volume resource IDs by region."
  value       = { for key, volume in azurerm_netapp_volume.this : key => volume.id }
}
