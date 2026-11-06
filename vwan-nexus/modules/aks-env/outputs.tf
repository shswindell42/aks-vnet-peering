output "cluster_name" {
  value = azapi_resource.aks.name
}

output "transit_cidr" {
  description = "The only prefix of this environment advertised to vWAN"
  value       = var.transit_cidr
}

output "aks_internal_cidr" {
  value = var.internal_cidr
}

output "aks_vnet_id" {
  value = azurerm_virtual_network.aks.id
}

output "nva_ilb_ip" {
  value = local.nva_ilb_ip
}

output "private_cluster" {
  value = var.private_cluster
}

output "api_server_private_fqdn" {
  value = try(azapi_resource.aks.output.properties.privateFQDN, null)
}

output "bastion_name" {
  value = local.bastion == 1 ? azurerm_bastion_host.aks[0].name : null
}

output "jumpbox_id" {
  value = local.bastion == 1 ? azurerm_linux_virtual_machine.jumpbox[0].id : null
}
