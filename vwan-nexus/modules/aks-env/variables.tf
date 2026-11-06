variable "name" {
  description = "Environment name (dev, qa, prod)"
  type        = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type = string
}

variable "virtual_hub_id" {
  description = "vWAN virtual hub the transit VNet connects to"
  type        = string
}

variable "transit_cidr" {
  description = "Small routable prefix (/28 recommended) for the transit VNet; the ONLY prefix advertised to the hub"
  type        = string
}

variable "internal_cidr" {
  description = "Non-routable AKS VNet space (never connected to the hub; may overlap across environments)"
  type        = string

  validation {
    condition     = tonumber(split("/", var.internal_cidr)[1]) <= 23
    error_message = "internal_cidr must be /23 or larger to hold the /28 API, /26 system and /24 user subnets."
  }
}

variable "destination_cidrs" {
  description = "Private prefixes (Nexus, on-prem) that AKS reaches through the transit NVA -> hub. Public clusters send everything else to the NAT gateway; private clusters send it through the transit too."
  type        = list(string)

  validation {
    condition     = length(var.destination_cidrs) > 0 && length(var.destination_cidrs) <= 50
    error_message = "destination_cidrs must contain between 1 and 50 prefixes; summarise on-prem ranges."
  }
}

variable "ssh_public_key" {
  type = string
}

variable "nva_vmss_sku" {
  type = string
}

variable "nva_vmss_instances" {
  type = number
}

variable "nva_zones" {
  type = list(string)
}

variable "admin_principal_id" {
  description = "Principal granted AKS RBAC Cluster Admin"
  type        = string
}

variable "next_hop_override" {
  description = "Optional private IP that replaces the NVA ILB as next hop for destination_cidrs (e.g. an Azure Firewall under test)."
  type        = string
  default     = null
}

variable "extra_peer_vnet" {
  description = "Optional VNet (e.g. an Azure Firewall transit under test) to peer with the AKS VNet before the cluster is created."
  type = object({
    id   = string
    name = string
  })
  default = null
}

variable "custom_ca_trust_certificates" {
  description = "PEM CA certificates added to the node trust store (AKS custom CA trust; max 10). Empty disables it."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.custom_ca_trust_certificates) <= 10
    error_message = "AKS custom CA trust accepts at most 10 certificates."
  }
}

variable "private_cluster" {
  description = "Private API server, and all egress forced through the transit next hop and the hub's default route (outboundType userDefinedRouting, no NAT gateway)."
  type        = bool
  default     = false
}

variable "create_bastion" {
  description = "PoC only: with private_cluster, create Azure Bastion (Standard, IP connect + tunnelling) in the AKS VNet to reach the private API server."
  type        = bool
  default     = false
}
