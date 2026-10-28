variable "subscription_id" {
  description = "Azure subscription ID for the deployment."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F-]{36}$", var.subscription_id))
    error_message = "subscription_id must be a GUID."
  }
}

variable "customer_name" {
  description = "Customer prefix used in resource group names."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9]([A-Za-z0-9-]{0,38}[A-Za-z0-9])?$", var.customer_name))
    error_message = "customer_name must contain 1-40 alphanumeric characters or hyphens and start/end with a letter or digit."
  }
}

variable "hub_location" {
  description = "Azure region for the hub and optional CVO/GFC network preparation."
  type        = string
  default     = "westeurope"
}

variable "spoke_location" {
  description = "Azure region for the Azure NetApp Files spoke."
  type        = string
  default     = "northeurope"
}

variable "deploy_ontap_network" {
  description = "Create an additional VNet and peering for a separate Cloud Volumes ONTAP deployment."
  type        = bool
  default     = false
}

variable "deploy_gfc_network" {
  description = "Create an additional VNet and peering for a separate Global File Cache deployment."
  type        = bool
  default     = false
}

variable "vm_admin_username" {
  description = "Local Windows administrator username for WinDC01."
  type        = string
  default     = "demoadmin"

  validation {
    condition     = length(var.vm_admin_username) >= 1 && length(var.vm_admin_username) <= 20 && !can(regex("[\\\\/@:]", var.vm_admin_username))
    error_message = "vm_admin_username must be 1-20 characters and cannot contain slash, backslash, @ or colon."
  }
}

variable "vm_admin_password" {
  description = "Local Windows administrator password. Supply through TF_VAR_vm_admin_password or a secret manager, not a committed tfvars file."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.vm_admin_password) >= 12
    error_message = "vm_admin_password must be at least 12 characters."
  }
}

variable "linux_vm_size" {
  description = "Azure VM size for the Ubuntu desktop/NFS client in North Europe."
  type        = string
  default     = "Standard_D2s_v5"
}

variable "linux_vm_admin_username" {
  description = "Linux user used for SSH and the XFCE/xrdp desktop session."
  type        = string
  default     = "demouser"

  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]{0,30}$", var.linux_vm_admin_username))
    error_message = "linux_vm_admin_username must be a valid lowercase Linux username."
  }
}

variable "linux_vm_admin_password" {
  description = "Linux password for SSH and xrdp. Supply through TF_VAR_linux_vm_admin_password or a secret manager, not a committed tfvars file."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.linux_vm_admin_password) >= 12
    error_message = "linux_vm_admin_password must be at least 12 characters."
  }
}

variable "dsrm_password" {
  description = "Separate Directory Services Restore Mode password. Supply through TF_VAR_dsrm_password or a secret manager. Terraform state can contain extension settings; protect the state backend."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.dsrm_password) >= 12
    error_message = "dsrm_password must be at least 12 characters."
  }
}

variable "ad_domain_name" {
  description = "Active Directory forest DNS name configured on the domain controller."
  type        = string
  default     = "anfdemo.intra"

  validation {
    condition     = can(regex("^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$", var.ad_domain_name))
    error_message = "ad_domain_name must be a valid DNS-style name."
  }
}

variable "tags" {
  description = "Additional tags applied to resources that support tags."
  type        = map(string)
  default     = {}
}
