# =============================================================================
# 8. PoC only: secured hub (create_hub_firewall = true)
#
# Stands in for the production hub firewall that forces internet egress. An Azure Firewall in the
# hub plus an Internet routing-intent policy makes the hub advertise 0.0.0.0/0 to every connection
# with internet_security_enabled = true. Only the transit connections of private clusters set it,
# so Nexus, on-prem and the firewall test path keep their own egress. Private traffic (transit <->
# Nexus/on-prem) has no routing policy and still goes hub-direct.
# =============================================================================
locals {
  hub_fw = var.create_hub_firewall && var.existing_virtual_hub_id == null ? 1 : 0
}

resource "azurerm_firewall_policy" "hub" {
  count               = local.hub_fw
  name                = "afwp-hub-egress"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "Standard"
}

# PoC: allow any outbound from the SNAT sources (the transit prefixes). A production hub firewall
# should allow only the AKS required outbound FQDNs/ports from these prefixes; this lab only
# proves the routing.
resource "azurerm_firewall_policy_rule_collection_group" "hub" {
  count              = local.hub_fw
  name               = "transit-egress"
  firewall_policy_id = azurerm_firewall_policy.hub[0].id
  priority           = 100

  network_rule_collection {
    name     = "allow-transit-to-internet"
    priority = 100
    action   = "Allow"

    rule {
      name                  = "transit-any"
      protocols             = ["TCP", "UDP"]
      source_addresses      = local.snat_source_cidrs
      destination_addresses = ["*"]
      destination_ports     = ["*"]
    }
  }
}

resource "azurerm_firewall" "hub" {
  count               = local.hub_fw
  name                = "afw-hub"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku_name            = "AZFW_Hub"
  sku_tier            = "Standard"
  firewall_policy_id  = azurerm_firewall_policy.hub[0].id

  virtual_hub {
    virtual_hub_id  = local.virtual_hub_id
    public_ip_count = 1
  }

  depends_on = [azurerm_firewall_policy_rule_collection_group.hub]
}

resource "azurerm_virtual_hub_routing_intent" "hub" {
  count          = local.hub_fw
  name           = "ri-hub-egress"
  virtual_hub_id = local.virtual_hub_id

  routing_policy {
    name         = "InternetTrafficPolicy"
    destinations = ["Internet"]
    next_hop     = azurerm_firewall.hub[0].id
  }
}
