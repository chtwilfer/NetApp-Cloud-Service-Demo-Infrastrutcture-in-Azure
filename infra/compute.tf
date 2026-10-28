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
    sku       = "2019-Datacenter"
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
