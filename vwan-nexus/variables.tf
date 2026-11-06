variable "resource_group_name" {
  description = "Resource group for all PoC resources"
  type        = string
  default     = "rg-aks-vwan-nexus"
}

variable "location" {
  description = "Azure region (AKS, transit VNets, and hub must be in the same region for this design)"
  type        = string
  default     = "westus3"
}

# -----------------------------------------------------------------------------
# Virtual WAN
# -----------------------------------------------------------------------------
variable "existing_virtual_hub_id" {
  description = "Resource ID of an existing vWAN virtual hub. When null, a Standard vWAN + hub are created for the PoC."
  type        = string
  default     = null
}

variable "private_clusters" {
  description = "Private AKS API servers, with ALL egress forced through each transit next hop and then the hub's default route (routing intent / secured hub). The hub firewall must allow the AKS required outbound FQDNs from the transit prefixes."
  type        = bool
  default     = true
}

variable "create_hub_firewall" {
  description = "PoC only: secure the PoC hub with an Azure Firewall and an Internet routing-intent policy, standing in for the production hub firewall that private clusters egress through"
  type        = bool
  default     = false
}

variable "create_bastion" {
  description = "PoC only: with private_clusters, create Azure Bastion (Standard, IP connect + tunnelling) per AKS VNet so the e2e script can tunnel to the private API server."
  type        = bool
  default     = false
}

variable "hub_address_prefix" {
  description = "Address prefix for the PoC virtual hub (ignored when existing_virtual_hub_id is set)"
  type        = string
  default     = "10.250.0.0/23"
}

# -----------------------------------------------------------------------------
# Nexus ("AKS Shared Infra" spoke)
# -----------------------------------------------------------------------------
variable "create_nexus_standin" {
  description = "Create a stand-in Nexus spoke VNet + VM connected to the hub. Set false to target an existing Nexus."
  type        = bool
  default     = true
}

variable "nexus_cidr" {
  description = "Prefix where Nexus is reachable through the hub. AKS UDRs send this prefix to the transit NVA."
  type        = string
  default     = "10.30.0.0/24"
}

variable "nexus_ip" {
  description = "Private IP of Nexus (stand-in VM IP, or the internal LB IP of the real Nexus service)"
  type        = string
  default     = "10.30.0.10"
}

variable "nexus_docker_port" {
  description = "Nexus Docker connector port (HTTP, bound to localhost; nginx terminates TLS on 443 in front of it)"
  type        = number
  default     = 8082
}

variable "private_dns_zone_name" {
  description = "Private DNS zone linked to the AKS VNets for the Nexus hostname"
  type        = string
  default     = "poc.internal"
}

variable "nexus_hostname" {
  description = "Host label of Nexus inside private_dns_zone_name (FQDN = <hostname>.<zone>)"
  type        = string
  default     = "nexus"
}

variable "nexus_image" {
  description = "Nexus container image for the stand-in VM"
  type        = string
  default     = "sonatype/nexus3:3.96.5"
}

variable "nexus_vm_sku" {
  description = "VM size for the stand-in Nexus VM (Nexus needs >= 8 GiB RAM)"
  type        = string
  default     = "Standard_D4s_v4"
}

# -----------------------------------------------------------------------------
# AKS environments
# -----------------------------------------------------------------------------
variable "environments" {
  description = <<-EOT
    One entry per AKS Automatic environment.
      transit_cidr  - small ROUTABLE prefix (/28) connected to the vWAN hub; must be unique per environment.
      internal_cidr - NON-routable AKS VNet space; never connected to the hub, so it may be identical in every environment.
  EOT
  type = map(object({
    transit_cidr  = string
    internal_cidr = string
  }))
  default = {
    dev = {
      transit_cidr  = "172.19.0.0/28"
      internal_cidr = "100.64.0.0/16"
    }
  }

  validation {
    condition     = length(distinct([for e in values(var.environments) : e.transit_cidr])) == length(var.environments)
    error_message = "transit_cidr must be unique per environment (they are all advertised to the same vWAN hub)."
  }
}

variable "nva_vmss_sku" {
  description = "VM size for the SNAT NVA instances (avoid burstable B-series on a data path)"
  type        = string
  default     = "Standard_D2s_v4"
}

variable "nva_vmss_instances" {
  description = "Number of SNAT NVA instances per environment"
  type        = number
  default     = 2
}

variable "nva_zones" {
  description = "Availability zones for the NVA VMSS (set [] in regions without zones)"
  type        = list(string)
  default     = ["1", "2", "3"]
}

variable "seed_image" {
  description = "Public image the test Job copies into Nexus and then pulls back to measure throughput"
  type        = string
  default     = "mcr.microsoft.com/dotnet/sdk:8.0"
}

variable "enable_custom_ca_trust" {
  description = "Add the PoC private root CA to every cluster's node trust store so kubelet can pull from Nexus over TLS."
  type        = bool
  default     = true
}

variable "onprem_cidrs" {
  description = "On-prem prefixes (learned by the hub over ExpressRoute/VPN) that AKS reaches through the transit NVA. Prefer a few summaries."
  type        = list(string)
  default     = []
}

variable "create_onprem_sim" {
  description = "PoC only: simulate on-prem with a VNet + VPN gateway connected to the hub by site-to-site VPN with BGP (propagates like ExpressRoute). Adds ~45 min and gateway costs."
  type        = bool
  default     = false
}

variable "onprem_sim_cidr" {
  description = "Address space of the simulated on-prem network (must not overlap the hub, Nexus, transit or AKS ranges)"
  type        = string
  default     = "10.40.0.0/24"
}

variable "onprem_sim_asn" {
  description = "BGP ASN of the simulated on-prem VPN device"
  type        = number
  default     = 65010
}

variable "create_azfw_test" {
  description = "PoC only: put an Azure Firewall (Standard, management NIC, no data-plane public IP) in its own transit VNet and route one environment through it instead of its NVA"
  type        = bool
  default     = false
}

variable "azfw_test_env" {
  description = "Environment whose AKS routes point at the Azure Firewall under test"
  type        = string
  default     = "prod"
}

variable "azfw_test_cidr" {
  description = "Routable /25 for the firewall transit VNet: AzureFirewallSubnet (/26) + AzureFirewallManagementSubnet (/26)"
  type        = string
  default     = "172.20.0.0/25"
}
