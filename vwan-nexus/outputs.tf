output "resource_group_name" {
  value = azurerm_resource_group.rg.name
}

output "virtual_hub_id" {
  value = local.virtual_hub_id
}

output "environments" {
  description = "Per-environment cluster name, advertised transit prefix, and non-routable AKS space"
  value = { for k, m in module.env : k => {
    cluster_name      = m.cluster_name
    transit_cidr      = m.transit_cidr
    aks_internal_cidr = m.aks_internal_cidr
    nva_ilb_ip        = m.nva_ilb_ip
    private_cluster   = m.private_cluster
    api_server_fqdn   = m.api_server_private_fqdn
    bastion_name      = m.bastion_name
    jumpbox_id        = m.jumpbox_id
  } }
}

output "nexus_registry" {
  value = local.nexus_fqdn
}

output "ca_cert_file" {
  description = "Private root CA (PEM) to install with az aks update --custom-ca-trust-certificates"
  value       = local_file.ca_cert.filename
}

output "nexus_admin_password" {
  description = "Stand-in Nexus admin password (PoC only)"
  value       = var.create_nexus_standin ? random_password.nexus_admin[0].result : null
  sensitive   = true
}

output "nexus_cidr" {
  description = "Nexus spoke prefix that each environment routes to its transit NVA"
  value       = var.nexus_cidr
}

output "private_destinations" {
  description = "Prefixes each environment routes through its transit NVA (Nexus + on-prem)"
  value       = local.private_destinations
}

output "onprem_sim" {
  description = "Simulated on-prem (create_onprem_sim): echo endpoint, gateway name, prefix"
  value = var.create_onprem_sim ? {
    cidr         = var.onprem_sim_cidr
    echo_url     = "http://${local.onprem_echo_ip}/"
    gateway_name = azurerm_virtual_network_gateway.onprem[0].name
  } : null
}

output "azfw_test" {
  description = "Azure Firewall under test (null unless create_azfw_test)"
  value = var.create_azfw_test ? {
    env        = var.azfw_test_env
    private_ip = local.azfw_private_ip
    subnet     = local.azfw_subnet
  } : null
}

output "ssh_private_key" {
  description = "PoC SSH key for the NVA and Bastion-only jump VMs"
  value       = tls_private_key.ssh.private_key_openssh
  sensitive   = true
}

output "hub_firewall_private_ip" {
  description = "PoC hub firewall (create_hub_firewall) that private clusters egress through"
  value       = var.create_hub_firewall ? azurerm_firewall.hub[0].virtual_hub[0].private_ip_address : null
}

output "hub_firewall_public_ips" {
  description = "Internet egress IPs of the PoC hub firewall (create_hub_firewall)"
  value       = var.create_hub_firewall ? azurerm_firewall.hub[0].virtual_hub[0].public_ip_addresses : []
}
