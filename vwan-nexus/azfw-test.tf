# =============================================================================
# 7. PoC only: Azure Firewall instead of the SNAT NVA (create_azfw_test = true)
#
# A second transit VNet holds an Azure Firewall Standard in management NIC mode, so the data
# path has no public IP. The firewall needs two /26 subnets, so this transit VNet is a /25
# (vs the /28 for an NVA). The chosen environment's AKS VNet peers to it and its route table
# points at the firewall's private IP. The firewall policy SNATs all traffic, including RFC 1918
# and 100.64.0.0/10 destinations, so Nexus and on-prem only ever see the firewall subnet.
# =============================================================================
locals {
  azfw            = var.create_azfw_test ? 1 : 0
  azfw_subnet     = cidrsubnet(var.azfw_test_cidr, 1, 0)
  azfw_mgmt       = cidrsubnet(var.azfw_test_cidr, 1, 1)
  azfw_private_ip = var.create_azfw_test ? azurerm_firewall.test[0].ip_configuration[0].private_ip_address : null
}

resource "azurerm_virtual_network" "azfw" {
  count               = local.azfw
  name                = "vnet-azfw-test"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = [var.azfw_test_cidr]

  lifecycle {
    precondition {
      condition     = contains(keys(var.environments), var.azfw_test_env)
      error_message = "azfw_test_env must be one of the environments."
    }
  }
}

resource "azurerm_subnet" "azfw" {
  count                = local.azfw
  name                 = "AzureFirewallSubnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.azfw[0].name
  address_prefixes     = [local.azfw_subnet]
}

resource "azurerm_subnet" "azfw_mgmt" {
  count                = local.azfw
  name                 = "AzureFirewallManagementSubnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.azfw[0].name
  address_prefixes     = [local.azfw_mgmt]
}

# Used only by Azure to manage the firewall; no customer traffic uses it.
resource "azurerm_public_ip" "azfw_mgmt" {
  count               = local.azfw
  name                = "pip-azfw-test-mgmt"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
}

resource "azurerm_firewall_policy" "azfw" {
  count               = local.azfw
  name                = "afwp-azfw-test"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "Standard"
  # Treat nothing as private, so every flow is SNATed to the firewall subnet.
  private_ip_ranges = ["255.255.255.255/32"]
}

resource "azurerm_firewall_policy_rule_collection_group" "azfw" {
  count              = local.azfw
  name               = "aks-to-private"
  firewall_policy_id = azurerm_firewall_policy.azfw[0].id
  priority           = 100

  network_rule_collection {
    name     = "allow-aks-to-private-destinations"
    priority = 100
    action   = "Allow"

    rule {
      name                  = "aks-to-nexus-and-onprem"
      protocols             = ["TCP"]
      source_addresses      = [var.environments[var.azfw_test_env].internal_cidr]
      destination_addresses = local.private_destinations
      destination_ports     = ["80", "443"]
    }
  }

  # Private clusters send all egress here (0.0.0.0/0 UDR); the firewall forwards it to the hub's
  # default route (forced tunnelling). PoC: any port; production should allow only the AKS
  # required outbound FQDNs/ports.
  dynamic "network_rule_collection" {
    for_each = var.private_clusters ? [1] : []
    content {
      name     = "allow-aks-egress"
      priority = 200
      action   = "Allow"

      rule {
        name                  = "aks-to-any"
        protocols             = ["TCP", "UDP"]
        source_addresses      = [var.environments[var.azfw_test_env].internal_cidr]
        destination_addresses = ["*"]
        destination_ports     = ["*"]
      }
    }
  }
}

resource "azurerm_firewall" "test" {
  count               = local.azfw
  name                = "afw-test"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku_name            = "AZFW_VNet"
  sku_tier            = "Standard"
  zones               = ["1", "2", "3"]
  firewall_policy_id  = azurerm_firewall_policy.azfw[0].id

  ip_configuration {
    name      = "data"
    subnet_id = azurerm_subnet.azfw[0].id
  }

  management_ip_configuration {
    name                 = "mgmt"
    subnet_id            = azurerm_subnet.azfw_mgmt[0].id
    public_ip_address_id = azurerm_public_ip.azfw_mgmt[0].id
  }

  depends_on = [azurerm_firewall_policy_rule_collection_group.azfw]
}

resource "azurerm_virtual_hub_connection" "azfw" {
  count                     = local.azfw
  name                      = "conn-azfw-test"
  virtual_hub_id            = local.virtual_hub_id
  remote_virtual_network_id = azurerm_virtual_network.azfw[0].id
  # Private clusters: AzureFirewallSubnet learns the hub's 0/0 (forced tunnelling); the management
  # subnet keeps its own system route to the internet.
  internet_security_enabled = var.private_clusters
}

# The AKS VNet <-> firewall VNet peerings live in modules/aks-env (extra_peer_vnet), so the
# private cluster is created only after its next hop is reachable.

