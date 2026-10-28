locals {
  customer_token = substr(replace(lower(var.customer_name), "/[^a-z0-9]/", ""), 0, 12)

  common_tags = merge(var.tags, {
    environment = "demo"
    workload    = "netapp-cloud-services"
    managed-by  = "terraform"
  })

  resource_group_names = {
    hub    = "${var.customer_name}-Demo-ANF-Hub"
    spoke  = "${var.customer_name}-Demo-ANF-Spoke"
    ontap  = "${var.customer_name}-Demo-ANF-Spoke-ONTAP"
    gfc    = "${var.customer_name}-Demo-ANF-Spoke-GFC"
  }

  domain_controller_script = templatefile("${path.module}/scripts/configure-adds.ps1.tftpl", {
    domain_name             = var.ad_domain_name
    dsrm_password_base64    = base64encode(var.dsrm_password)
  })

  domain_controller_command = join(" ", [
    "powershell.exe",
    "-NoProfile",
    "-ExecutionPolicy Bypass",
    "-EncodedCommand",
    textencodebase64(local.domain_controller_script, "UTF-16LE")
  ])

  linux_bootstrap_script = replace(templatefile("${path.module}/scripts/configure-ubuntu-desktop.sh.tftpl", {
    linux_username   = var.linux_vm_admin_username
    anf_mount_target = azurerm_netapp_volume.this["north_europe"].ip_address
    anf_volume_path  = local.anf_regions.north_europe.volume_path
    mount_path       = "/mnt/anf-demo"
  }), "\r\n", "\n")

  linux_bootstrap_command = "echo ${base64encode(local.linux_bootstrap_script)} | base64 --decode | bash"
}
