resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
}

# =============================================================================
# 1. AKS Virtual Network (Isolated CGNAT Space - Never Connected to vWAN Hub)
# =============================================================================
resource "azurerm_virtual_network" "aks_vnet" {
  name                = "vnet-aks-automatic"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space = [
    var.aks_vnet_internal_cidr,
  ]
}

# Subnet 1: API Server VNet Integration
resource "azurerm_subnet" "aks_api" {
  name                 = "snet-aks-api"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.aks_vnet.name
  address_prefixes     = [var.aks_api_subnet_cidr]

  delegation {
    name = "aks-api-delegation"
    service_delegation {
      name    = "Microsoft.ContainerService/managedClusters"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# Subnet 2: Managed System Nodes
resource "azurerm_subnet" "aks_system_nodes" {
  name                 = "snet-aks-system"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.aks_vnet.name
  address_prefixes     = [var.aks_system_node_subnet_cidr]

  lifecycle {
    ignore_changes = [delegation]
  }
}

# Subnet 3: User Nodes (/24 required by AKS Automatic, Non-routable in vWAN)
resource "azurerm_subnet" "aks_user_nodes" {
  name                 = "snet-aks-user-nodes"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.aks_vnet.name
  address_prefixes     = [var.aks_user_node_subnet_cidr]
}

# =============================================================================
# 2. NAT Transit Virtual Network (Tiny /28 Spoke Connected to vWAN Hub)
# =============================================================================
resource "azurerm_virtual_network" "nat_transit_vnet" {
  name                = "vnet-nat-transit"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = [var.nat_subnet_cidr]
}

resource "azurerm_subnet" "nat_masquerade" {
  name                 = "snet-nat-masquerade"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.nat_transit_vnet.name
  address_prefixes     = [var.nat_subnet_cidr]
}

# =============================================================================
# 3. Local VNet Peering: AKS VNet <-> NAT Transit VNet
# =============================================================================
# This local peering allows AKS nodes (100.64.0.0/16) to use the Internal LB
# (10.100.0.4) in vnet-nat-transit as a VirtualAppliance next-hop without
# exposing 100.64.0.0/16 to the Azure Virtual WAN Hub.
resource "azurerm_virtual_network_peering" "aks_to_nat_transit" {
  name                         = "peer-aks-to-nat-transit"
  resource_group_name          = azurerm_resource_group.rg.name
  virtual_network_name         = azurerm_virtual_network.aks_vnet.name
  remote_virtual_network_id    = azurerm_virtual_network.nat_transit_vnet.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

resource "azurerm_virtual_network_peering" "nat_transit_to_aks" {
  name                         = "peer-nat-transit-to-aks"
  resource_group_name          = azurerm_resource_group.rg.name
  virtual_network_name         = azurerm_virtual_network.nat_transit_vnet.name
  remote_virtual_network_id    = azurerm_virtual_network.aks_vnet.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

# =============================================================================
# 4. NAT Gateway for AKS Outbound Internet Access
# =============================================================================
resource "azurerm_public_ip" "nat_gw_pip" {
  name                = "pip-nat-gateway"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_nat_gateway" "aks_nat_gw" {
  name                = "ngw-aks-vnet"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku_name            = "Standard"
}

resource "azurerm_nat_gateway_public_ip_association" "aks_nat_gw_assoc" {
  nat_gateway_id       = azurerm_nat_gateway.aks_nat_gw.id
  public_ip_address_id = azurerm_public_ip.nat_gw_pip.id
}

resource "azurerm_subnet_nat_gateway_association" "user_nodes_nat" {
  subnet_id      = azurerm_subnet.aks_user_nodes.id
  nat_gateway_id = azurerm_nat_gateway.aks_nat_gw.id
}

resource "azurerm_subnet_nat_gateway_association" "system_nodes_nat" {
  subnet_id      = azurerm_subnet.aks_system_nodes.id
  nat_gateway_id = azurerm_nat_gateway.aks_nat_gw.id
}

# =============================================================================
# 5. Remote Services Virtual Network (Connected to vWAN Hub)
# =============================================================================
resource "azurerm_virtual_network" "remote_vnet" {
  name                = "vnet-remote-services"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = [var.remote_vnet_cidr]
}

resource "azurerm_subnet" "remote_api" {
  name                 = "snet-remote-api"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.remote_vnet.name
  address_prefixes     = [var.remote_api_subnet_cidr]
}

# =============================================================================
# 6. Azure Virtual WAN & Virtual Hub (Connecting NAT Transit <-> Remote VNet)
# =============================================================================
resource "azurerm_virtual_wan" "vwan" {
  name                           = "vwan-enterprise"
  resource_group_name            = azurerm_resource_group.rg.name
  location                       = azurerm_resource_group.rg.location
  type                           = "Standard"
  allow_branch_to_branch_traffic = true
}

resource "azurerm_virtual_hub" "vhub" {
  name                = "vhub-central"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  virtual_wan_id      = azurerm_virtual_wan.vwan.id
  address_prefix      = var.vhub_address_prefix
  sku                 = "Standard"
}

# Connect the tiny /28 NAT Transit VNet to the Virtual WAN Hub
resource "azurerm_virtual_hub_connection" "nat_transit_to_vhub" {
  name                      = "conn-nat-transit-to-vhub"
  virtual_hub_id            = azurerm_virtual_hub.vhub.id
  remote_virtual_network_id = azurerm_virtual_network.nat_transit_vnet.id
  internet_security_enabled = false
}

# Connect the Remote Services VNet to the Virtual WAN Hub
resource "azurerm_virtual_hub_connection" "remote_services_to_vhub" {
  name                      = "conn-remote-services-to-vhub"
  virtual_hub_id            = azurerm_virtual_hub.vhub.id
  remote_virtual_network_id = azurerm_virtual_network.remote_vnet.id
  internet_security_enabled = false
}

# =============================================================================
# 7. User-Defined Route (UDR) for AKS Subnets -> Internal Load Balancer
# =============================================================================
resource "azurerm_route_table" "aks_to_remote_rt" {
  name                = "rt-aks-to-remote-vnet"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  route {
    name                   = "route-to-remote-vnet-via-nat-vmss"
    address_prefix         = var.remote_vnet_cidr
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = azurerm_lb.nat_ilb.frontend_ip_configuration[0].private_ip_address
  }

  route {
    name                   = "route-to-remote-api-subnet-via-nat-vmss"
    address_prefix         = var.remote_api_subnet_cidr
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = azurerm_lb.nat_ilb.frontend_ip_configuration[0].private_ip_address
  }
}

resource "azurerm_subnet_route_table_association" "user_nodes_rt_assoc" {
  subnet_id      = azurerm_subnet.aks_user_nodes.id
  route_table_id = azurerm_route_table.aks_to_remote_rt.id
}

resource "azurerm_subnet_route_table_association" "system_nodes_rt_assoc" {
  subnet_id      = azurerm_subnet.aks_system_nodes.id
  route_table_id = azurerm_route_table.aks_to_remote_rt.id
}
