# =============================================================================
# Render the Kubernetes Test Job Manifest with Deployed IP Values
# =============================================================================
resource "local_file" "test_job_manifest" {
  filename = "${path.module}/k8s/test-peered-api-job.yaml"
  content = templatefile("${path.module}/k8s/test-peered-api-job.yaml.tftpl", {
    api_url    = "http://${var.remote_api_private_ip}:8080/health"
    nat_prefix = "${join(".", slice(split(".", cidrhost(var.nat_subnet_cidr, 0)), 0, 3))}."
  })
}

# =============================================================================
# Outputs
# =============================================================================
output "resource_group_name" {
  description = "Azure Resource Group name"
  value       = azurerm_resource_group.rg.name
}

output "aks_cluster_name" {
  description = "AKS Automatic cluster name"
  value       = azurerm_kubernetes_automatic_cluster.aks.name
}

output "aks_user_node_subnet_cidr" {
  description = "Non-peered /24 subnet CIDR used by AKS user nodes"
  value       = var.aks_user_node_subnet_cidr
}

output "peered_nat_subnet_cidr" {
  description = "Small /28 NAT Transit VNet CIDR connected to the Virtual WAN Hub"
  value       = var.nat_subnet_cidr
}

output "virtual_wan_hub_id" {
  description = "Azure Virtual WAN Hub Resource ID"
  value       = azurerm_virtual_hub.vhub.id
}

output "nat_ilb_private_ip" {
  description = "Internal Load Balancer IP (Next-hop for AKS UDR)"
  value       = azurerm_lb.nat_ilb.frontend_ip_configuration[0].private_ip_address
}

output "remote_api_endpoint" {
  description = "HTTP endpoint of the test API hosted in the peered VNet"
  value       = "http://${var.remote_api_private_ip}:8080/health"
}

output "run_test_job_commands" {
  description = "Commands to authenticate to AKS Automatic and run the test Job"
  value       = <<-EOT
    az aks get-credentials --resource-group ${azurerm_resource_group.rg.name} --name ${azurerm_kubernetes_automatic_cluster.aks.name} --overwrite-existing
    kubectl apply -f k8s/test-peered-api-job.yaml
    kubectl wait --for=condition=complete --timeout=180s job/test-peered-api-connectivity
    kubectl logs job/test-peered-api-connectivity
  EOT
}