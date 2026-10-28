resource "azurerm_network_interface" "domain_controller" {
  name                = "WinDC01Nic"
  location            = azurerm_resource_group.this["hub"].location
  resource_group_name = azurerm_resource_group.this["hub"].name
  tags                = local.common_tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.this["hub.domain"].id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_windows_virtual_machine" "domain_controller" {
  name                = "WinDC01"
  computer_name       = "WinDC01"
  resource_group_name = azurerm_resource_group.this["hub"].name
  location            = azurerm_resource_group.this["hub"].location
  size                = "Standard_D2_v3"
  admin_username      = var.vm_admin_username
  admin_password      = var.vm_admin_password
  network_interface_ids = [
    azurerm_network_interface.domain_controller.id
  ]
  provision_vm_agent         = true
  enable_automatic_updates   = true
  patch_mode                 = "AutomaticByOS"
  tags                       = local.common_tags

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2025-datacenter"
    version   = "latest"
  }

  boot_diagnostics {}
}

resource "azurerm_virtual_machine_extension" "configure_active_directory" {
  name                       = "AD-Setup"
  virtual_machine_id         = azurerm_windows_virtual_machine.domain_controller.id
  publisher                  = "Microsoft.Compute"
  type                       = "CustomScriptExtension"
  type_handler_version       = "1.10"
  auto_upgrade_minor_version = true
  protected_settings         = jsonencode({ commandToExecute = local.domain_controller_command })
  tags                       = local.common_tags
}

resource "azurerm_network_interface" "linux_client" {
  name                = "UbuntuNfs01Nic"
  location            = azurerm_resource_group.this["spoke"].location
  resource_group_name = azurerm_resource_group.this["spoke"].name
  tags                = local.common_tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.this["spoke.linux_client"].id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_network_interface_security_group_association" "linux_client" {
  network_interface_id      = azurerm_network_interface.linux_client.id
  network_security_group_id = azurerm_network_security_group.linux_client.id
}

resource "azurerm_linux_virtual_machine" "nfs_client" {
  name                            = "UbuntuNfs01"
  computer_name                   = "UbuntuNfs01"
  resource_group_name             = azurerm_resource_group.this["spoke"].name
  location                        = azurerm_resource_group.this["spoke"].location
  size                            = var.linux_vm_size
  admin_username                  = var.linux_vm_admin_username
  admin_password                  = var.linux_vm_admin_password
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.linux_client.id]
  provision_vm_agent              = true
  patch_mode                      = "ImageDefault"
  tags                            = local.common_tags

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  boot_diagnostics {}
}

resource "azurerm_virtual_machine_extension" "configure_linux_desktop_and_anf" {
  name                       = "LinuxDesktopAndAnfMount"
  virtual_machine_id         = azurerm_linux_virtual_machine.nfs_client.id
  publisher                  = "Microsoft.Azure.Extensions"
  type                       = "CustomScript"
  type_handler_version       = "2.1"
  auto_upgrade_minor_version = true
  settings                   = jsonencode({ commandToExecute = local.linux_bootstrap_command })
  tags                       = local.common_tags
}
