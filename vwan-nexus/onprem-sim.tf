# =============================================================================
# 6. PoC only: simulated on-prem (create_onprem_sim = true)
#
# A VNet with a VPN gateway stands in for the data centres. It connects to the hub with a
# site-to-site VPN and BGP. A branch connection propagates routes like ExpressRoute: the hub
# advertises its connected VNets (transit /28s, Nexus) to the branch, and the branch prefixes
# reach every VNet connection on the default route table.
# =============================================================================
locals {
  onprem_sim         = var.create_onprem_sim ? 1 : 0
  onprem_gw_subnet   = cidrsubnet(var.onprem_sim_cidr, 3, 0) # /27 from a /24
  onprem_vm_subnet   = cidrsubnet(var.onprem_sim_cidr, 3, 1)
  onprem_echo_ip     = cidrhost(local.onprem_vm_subnet, 8)
  hub_vpn_instance_0 = var.create_onprem_sim ? azurerm_vpn_gateway.hub[0].bgp_settings[0].instance_0_bgp_peering_address[0] : null
  hub_vpn_instance_0_public_ip = var.create_onprem_sim ? one([
    for c in azurerm_vpn_gateway.hub[0].ip_configuration : c.public_ip_address
    if lower(c.id) == lower(local.hub_vpn_instance_0.ip_configuration_id)
  ]) : null
}

resource "random_password" "vpn_psk" {
  count   = local.onprem_sim
  length  = 32
  special = false
}

# --- Hub side ----------------------------------------------------------------
resource "azurerm_vpn_gateway" "hub" {
  count               = local.onprem_sim
  name                = "vpngw-hub-${var.location}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  virtual_hub_id      = local.virtual_hub_id
  scale_unit          = 1

  timeouts {
    create = "90m"
    delete = "90m"
  }

  lifecycle {
    precondition {
      condition     = var.existing_virtual_hub_id == null
      error_message = "create_onprem_sim only works with the PoC hub. On a real hub, set onprem_cidrs to the prefixes learned over ExpressRoute."
    }
  }
}

resource "azurerm_vpn_site" "onprem" {
  count               = local.onprem_sim
  name                = "vpnsite-onprem-sim"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  virtual_wan_id      = azurerm_virtual_wan.vwan[0].id
  device_vendor       = "Azure"
  device_model        = "VpnGw1AZ"

  link {
    name          = "link-onprem-sim"
    ip_address    = azurerm_public_ip.onprem_vpngw[0].ip_address
    speed_in_mbps = 650

    bgp {
      asn             = var.onprem_sim_asn
      peering_address = azurerm_virtual_network_gateway.onprem[0].bgp_settings[0].peering_addresses[0].default_addresses[0]
    }
  }
}

resource "azurerm_vpn_gateway_connection" "onprem" {
  count                     = local.onprem_sim
  name                      = "conn-onprem-sim"
  vpn_gateway_id            = azurerm_vpn_gateway.hub[0].id
  remote_vpn_site_id        = azurerm_vpn_site.onprem[0].id
  internet_security_enabled = false

  vpn_link {
    name             = "link-onprem-sim"
    vpn_site_link_id = azurerm_vpn_site.onprem[0].link[0].id
    bgp_enabled      = true
    shared_key       = random_password.vpn_psk[0].result
  }
}

# --- Simulated on-prem side --------------------------------------------------
resource "azurerm_virtual_network" "onprem" {
  count               = local.onprem_sim
  name                = "vnet-onprem-sim"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = [var.onprem_sim_cidr]
}

resource "azurerm_subnet" "onprem_gateway" {
  count                = local.onprem_sim
  name                 = "GatewaySubnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.onprem[0].name
  address_prefixes     = [local.onprem_gw_subnet]
}

resource "azurerm_subnet" "onprem_vm" {
  count                = local.onprem_sim
  name                 = "snet-onprem-servers"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.onprem[0].name
  address_prefixes     = [local.onprem_vm_subnet]
}

resource "azurerm_public_ip" "onprem_vpngw" {
  count               = local.onprem_sim
  name                = "pip-onprem-vpngw"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = var.nva_zones
}

resource "azurerm_virtual_network_gateway" "onprem" {
  count               = local.onprem_sim
  name                = "vng-onprem-sim"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  type                = "Vpn"
  vpn_type            = "RouteBased"
  sku                 = "VpnGw1AZ"
  generation          = "Generation1"
  active_active       = false
  bgp_enabled         = true

  ip_configuration {
    name                 = "vnetGatewayConfig"
    public_ip_address_id = azurerm_public_ip.onprem_vpngw[0].id
    subnet_id            = azurerm_subnet.onprem_gateway[0].id
  }

  bgp_settings {
    asn = var.onprem_sim_asn
  }

  timeouts {
    create = "90m"
    delete = "90m"
  }
}

resource "azurerm_local_network_gateway" "hub" {
  count               = local.onprem_sim
  name                = "lng-vwan-hub-instance0"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  gateway_address     = local.hub_vpn_instance_0_public_ip
  address_space       = ["${tolist(local.hub_vpn_instance_0.default_ips)[0]}/32"]

  bgp_settings {
    asn                 = azurerm_vpn_gateway.hub[0].bgp_settings[0].asn
    bgp_peering_address = tolist(local.hub_vpn_instance_0.default_ips)[0]
  }
}

resource "azurerm_virtual_network_gateway_connection" "onprem_to_hub" {
  count                      = local.onprem_sim
  name                       = "conn-onprem-to-vwan"
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  type                       = "IPsec"
  virtual_network_gateway_id = azurerm_virtual_network_gateway.onprem[0].id
  local_network_gateway_id   = azurerm_local_network_gateway.hub[0].id
  bgp_enabled                = true
  shared_key                 = random_password.vpn_psk[0].result
}

# An "on-prem server": answers HTTP with the source IP it sees. Only the transit /28s may connect,
# so a successful answer from AKS proves the NVA SNAT and the hub -> branch path.
resource "azurerm_network_security_group" "onprem_vm" {
  count               = local.onprem_sim
  name                = "nsg-onprem-servers"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name                       = "Allow-Transit-To-Echo"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefixes    = local.snat_source_cidrs
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Deny-Other-VNet-Inbound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "onprem_vm" {
  count                     = local.onprem_sim
  subnet_id                 = azurerm_subnet.onprem_vm[0].id
  network_security_group_id = azurerm_network_security_group.onprem_vm[0].id
}

resource "azurerm_network_interface" "onprem_echo" {
  count               = local.onprem_sim
  name                = "nic-onprem-echo"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "ipconfig-echo"
    subnet_id                     = azurerm_subnet.onprem_vm[0].id
    private_ip_address_allocation = "Static"
    private_ip_address            = local.onprem_echo_ip
  }
}

resource "azurerm_linux_virtual_machine" "onprem_echo" {
  count                 = local.onprem_sim
  name                  = "vm-onprem-echo"
  resource_group_name   = azurerm_resource_group.rg.name
  location              = azurerm_resource_group.rg.location
  size                  = var.nva_vmss_sku
  admin_username        = "azureuser"
  network_interface_ids = [azurerm_network_interface.onprem_echo[0].id]

  admin_ssh_key {
    username   = "azureuser"
    public_key = tls_private_key.ssh.public_key_openssh
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  os_disk {
    storage_account_type = "Premium_LRS"
    caching              = "ReadWrite"
  }

  # No internet egress needed: python3 ships with the image.
  custom_data = base64encode(file("${path.module}/onprem-echo-cloud-init.yaml"))

  depends_on = [azurerm_subnet_network_security_group_association.onprem_vm]
}
