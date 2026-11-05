variable "resource_group_name" {
  description = "Name of the Azure Resource Group"
  type        = string
  default     = "rg-aks-subnet-peering"
}

variable "location" {
  description = "Azure region for all resources"
  type        = string
  default     = "centralus"
}

variable "cluster_name" {
  description = "Name of the AKS Automatic cluster"
  type        = string
  default     = "aks-auto-masquerade"
}

# -----------------------------------------------------------------------------
# AKS VNet & NAT Transit VNet Address Spaces
# -----------------------------------------------------------------------------
# 1. Non-vWAN /16 CGNAT (or private) CIDR for AKS internal subnets (API server, system nodes, /24 user nodes)
variable "aks_vnet_internal_cidr" {
  description = "Non-routable CIDR space for AKS Automatic subnets (never advertised to Virtual WAN Hub)"
  type        = string
  default     = "100.64.0.0/16"
}

variable "aks_api_subnet_cidr" {
  description = "Subnet CIDR for AKS API Server VNet integration (/28 minimum)"
  type        = string
  default     = "100.64.0.0/28"
}

variable "aks_system_node_subnet_cidr" {
  description = "Subnet CIDR for AKS Managed System Nodes (/26 minimum)"
  type        = string
  default     = "100.64.0.64/26"
}

variable "aks_user_node_subnet_cidr" {
  description = "Subnet CIDR for AKS User Nodes (/24 required by AKS Automatic)"
  type        = string
  default     = "100.64.1.0/24"
}

# 2. Small /28 Transit VNet dedicated to the IP Masquerade VMSS (connected to Virtual WAN Hub)
variable "nat_subnet_cidr" {
  description = "Address space and subnet CIDR for the NAT Transit VNet (connected to Virtual WAN Hub)"
  type        = string
  default     = "10.100.0.0/28"
}

variable "nat_lb_private_ip" {
  description = "Static private IP address for the Internal Load Balancer frontend in the NAT Transit VNet"
  type        = string
  default     = "10.100.0.4"
}

# -----------------------------------------------------------------------------
# Azure Virtual WAN Hub Address Space
# -----------------------------------------------------------------------------
variable "vhub_address_prefix" {
  description = "Address prefix for the Azure Virtual WAN Hub (/24 minimum recommended by Azure)"
  type        = string
  default     = "10.50.0.0/24"
}

# -----------------------------------------------------------------------------
# Peered Remote VNet Address Spaces
# -----------------------------------------------------------------------------
variable "remote_vnet_cidr" {
  description = "Address space for the remote peered VNet"
  type        = string
  default     = "10.200.0.0/16"
}

variable "remote_api_subnet_cidr" {
  description = "Subnet CIDR for the API service in the remote peered VNet"
  type        = string
  default     = "10.200.1.0/24"
}

variable "remote_api_private_ip" {
  description = "Static private IP for the test API VM in the remote peered VNet"
  type        = string
  default     = "10.200.1.10"
}

# -----------------------------------------------------------------------------
# Compute Settings
# -----------------------------------------------------------------------------
variable "nat_vmss_sku" {
  description = "VM SKU for the IP Masquerade VMSS"
  type        = string
  default     = "Standard_B2s_v2"
}

variable "nat_vmss_instances" {
  description = "Number of instances in the IP Masquerade VMSS"
  type        = number
  default     = 2
}

variable "api_vm_sku" {
  description = "VM SKU for the target API server in the peered VNet"
  type        = string
  default     = "Standard_B1s"
}

