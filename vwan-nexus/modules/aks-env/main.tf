locals {
  internal_len = tonumber(split("/", var.internal_cidr)[1])

  aks_api_subnet_cidr    = cidrsubnet(var.internal_cidr, 28 - local.internal_len, 0)  # x.x.0.0/28
  aks_system_subnet_cidr = cidrsubnet(var.internal_cidr, 26 - local.internal_len, 1)  # x.x.0.64/26
  aks_user_subnet_cidr   = cidrsubnet(var.internal_cidr, 24 - local.internal_len, 1)  # x.x.1.0/24
  jumpbox_subnet_cidr    = cidrsubnet(var.internal_cidr, 28 - local.internal_len, 32) # x.x.2.0/28
  bastion_subnet_cidr    = cidrsubnet(var.internal_cidr, 26 - local.internal_len, 9)  # x.x.2.64/26

  nva_ilb_ip = cidrhost(var.transit_cidr, 4)
  next_hop   = coalesce(var.next_hop_override, local.nva_ilb_ip)

  resource_group_id = join("/", slice(split("/", azurerm_virtual_network.aks.id), 0, 5))

  # Private cluster: all egress (internet included) is forced through the transit next hop and
  # then the hub's default route, so there is no NAT gateway and the NVA SNATs everything.
  natgw = var.private_cluster ? 0 : 1
}

# =============================================================================
# 1. Transit VNet (routable /28) - the ONLY VNet of this environment connected to vWAN
# =============================================================================
resource "azurerm_virtual_network" "transit" {
  name                = "vnet-${var.name}-transit"
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = [var.transit_cidr]
}

resource "azurerm_subnet" "nva" {
  name                 = "snet-nva"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.transit.name
  address_prefixes     = [var.transit_cidr]
}

resource "azurerm_virtual_hub_connection" "transit" {
  name                      = "conn-${var.name}-transit"
  virtual_hub_id            = var.virtual_hub_id
  remote_virtual_network_id = azurerm_virtual_network.transit.id
  # true = propagate the hub's default route (routing intent / secured hub) into the transit VNet.
  internet_security_enabled = var.private_cluster
}

# =============================================================================
# 2. AKS VNet (non-routable) - never connected to the hub, only peered to its transit VNet
# =============================================================================
resource "azurerm_virtual_network" "aks" {
  name                = "vnet-${var.name}-aks"
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = [var.internal_cidr]
}

resource "azurerm_subnet" "aks_api" {
  name                 = "snet-aks-api"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.aks.name
  address_prefixes     = [local.aks_api_subnet_cidr]

  delegation {
    name = "aks-api-delegation"
    service_delegation {
      name    = "Microsoft.ContainerService/managedClusters"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "aks_system" {
  name                 = "snet-aks-system"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.aks.name
  address_prefixes     = [local.aks_system_subnet_cidr]

  lifecycle {
    ignore_changes = [delegation]
  }
}

resource "azurerm_subnet" "aks_user" {
  name                 = "snet-aks-user-nodes"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.aks.name
  address_prefixes     = [local.aks_user_subnet_cidr]
}

# Plain VNet peering AKS <-> transit. vWAN does not propagate the AKS prefix (peering is non-transitive),
# so the hub only ever learns the transit /28.
resource "azurerm_virtual_network_peering" "aks_to_transit" {
  name                         = "peer-${var.name}-aks-to-transit"
  resource_group_name          = var.resource_group_name
  virtual_network_name         = azurerm_virtual_network.aks.name
  remote_virtual_network_id    = azurerm_virtual_network.transit.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

resource "azurerm_virtual_network_peering" "transit_to_aks" {
  name                         = "peer-${var.name}-transit-to-aks"
  resource_group_name          = var.resource_group_name
  virtual_network_name         = azurerm_virtual_network.transit.name
  remote_virtual_network_id    = azurerm_virtual_network.aks.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
}

# Optional peering to an alternative next hop (PoC Azure Firewall transit).
resource "azurerm_virtual_network_peering" "aks_to_extra" {
  count                     = var.extra_peer_vnet == null ? 0 : 1
  name                      = "peer-aks-to-${trimprefix(var.extra_peer_vnet.name, "vnet-")}"
  resource_group_name       = var.resource_group_name
  virtual_network_name      = azurerm_virtual_network.aks.name
  remote_virtual_network_id = var.extra_peer_vnet.id
  allow_forwarded_traffic   = true
}

resource "azurerm_virtual_network_peering" "extra_to_aks" {
  count                     = var.extra_peer_vnet == null ? 0 : 1
  name                      = "peer-${trimprefix(var.extra_peer_vnet.name, "vnet-")}-to-aks"
  resource_group_name       = var.resource_group_name
  virtual_network_name      = var.extra_peer_vnet.name
  remote_virtual_network_id = azurerm_virtual_network.aks.id
  allow_forwarded_traffic   = true
}

# =============================================================================
# 3. Internet egress for public clusters only (MCR, AKS endpoints) - not via the hub.
#    Private clusters have none: their egress is forced through the transit and the hub.
# =============================================================================
resource "azurerm_public_ip" "natgw" {
  count               = local.natgw
  name                = "pip-${var.name}-natgw"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_nat_gateway" "aks" {
  count               = local.natgw
  name                = "ngw-${var.name}-aks"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku_name            = "Standard"
}

resource "azurerm_nat_gateway_public_ip_association" "aks" {
  count                = local.natgw
  nat_gateway_id       = azurerm_nat_gateway.aks[0].id
  public_ip_address_id = azurerm_public_ip.natgw[0].id
}

resource "azurerm_subnet_nat_gateway_association" "aks_system" {
  count          = local.natgw
  subnet_id      = azurerm_subnet.aks_system.id
  nat_gateway_id = azurerm_nat_gateway.aks[0].id
}

resource "azurerm_subnet_nat_gateway_association" "aks_user" {
  count          = local.natgw
  subnet_id      = azurerm_subnet.aks_user.id
  nat_gateway_id = azurerm_nat_gateway.aks[0].id
}

# =============================================================================
# 4. UDR: private destinations (Nexus, on-prem) -> NVA internal LB in the peered transit VNet.
#    Private clusters also send 0.0.0.0/0 there (AKS outboundType userDefinedRouting).
# =============================================================================
resource "azurerm_route_table" "aks" {
  name                = "rt-${var.name}-aks-to-nexus"
  location            = var.location
  resource_group_name = var.resource_group_name

  dynamic "route" {
    for_each = var.destination_cidrs
    content {
      name                   = "via-transit-nva-${replace(route.value, "/[./]/", "-")}"
      address_prefix         = route.value
      next_hop_type          = "VirtualAppliance"
      next_hop_in_ip_address = local.next_hop
    }
  }

  dynamic "route" {
    for_each = var.private_cluster ? [1] : []
    content {
      name                   = "default-via-transit"
      address_prefix         = "0.0.0.0/0"
      next_hop_type          = "VirtualAppliance"
      next_hop_in_ip_address = local.next_hop
    }
  }
}

resource "azurerm_subnet_route_table_association" "aks_system" {
  subnet_id      = azurerm_subnet.aks_system.id
  route_table_id = azurerm_route_table.aks.id
}

resource "azurerm_subnet_route_table_association" "aks_user" {
  subnet_id      = azurerm_subnet.aks_user.id
  route_table_id = azurerm_route_table.aks.id
}

# =============================================================================
# 5. SNAT NVA (ILB HA ports + Linux VMSS) in the transit VNet
# =============================================================================
resource "azurerm_lb" "nva" {
  name                = "ilb-${var.name}-nva"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "Standard"

  frontend_ip_configuration {
    name                          = "fe-nva"
    subnet_id                     = azurerm_subnet.nva.id
    private_ip_address_allocation = "Static"
    private_ip_address            = local.nva_ilb_ip
    zones                         = length(var.nva_zones) > 0 ? var.nva_zones : null
  }
}

resource "azurerm_lb_backend_address_pool" "nva" {
  loadbalancer_id = azurerm_lb.nva.id
  name            = "bepool-nva"
}

# HTTP probe served by the NVA itself; returns 200 only when forwarding + SNAT are configured.
resource "azurerm_lb_probe" "nva" {
  loadbalancer_id     = azurerm_lb.nva.id
  name                = "probe-nva-health"
  protocol            = "Http"
  port                = 8080
  request_path        = "/healthz"
  interval_in_seconds = 5
  number_of_probes    = 2
}

resource "azurerm_lb_rule" "ha_ports" {
  loadbalancer_id                = azurerm_lb.nva.id
  name                           = "rule-ha-ports"
  protocol                       = "All"
  frontend_port                  = 0
  backend_port                   = 0
  frontend_ip_configuration_name = "fe-nva"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.nva.id]
  probe_id                       = azurerm_lb_probe.nva.id
  floating_ip_enabled            = true
  disable_outbound_snat          = true
}

resource "azurerm_network_security_group" "nva" {
  name                = "nsg-${var.name}-nva"
  location            = var.location
  resource_group_name = var.resource_group_name

  security_rule {
    name                       = "Allow-AKS-To-NVA"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = var.internal_cidr
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-AzureLoadBalancer-Probe"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8080"
    source_address_prefix      = "AzureLoadBalancer"
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

resource "azurerm_subnet_network_security_group_association" "nva" {
  subnet_id                 = azurerm_subnet.nva.id
  network_security_group_id = azurerm_network_security_group.nva.id
}

resource "azurerm_linux_virtual_machine_scale_set" "nva" {
  name                        = "vmss-${var.name}-nva"
  resource_group_name         = var.resource_group_name
  location                    = var.location
  sku                         = var.nva_vmss_sku
  instances                   = var.nva_vmss_instances
  admin_username              = "azureuser"
  upgrade_mode                = "Manual"
  zones                       = length(var.nva_zones) > 0 ? var.nva_zones : null
  zone_balance                = length(var.nva_zones) > 1
  platform_fault_domain_count = 1
  single_placement_group      = false

  admin_ssh_key {
    username   = "azureuser"
    public_key = var.ssh_public_key
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

  custom_data = base64encode(templatefile("${path.module}/nva-cloud-init.yaml.tftpl", {
    internal_cidr     = var.internal_cidr
    destination_cidrs = var.destination_cidrs
    snat_all          = var.private_cluster
  }))

  network_interface {
    name                           = "nic-nva"
    primary                        = true
    ip_forwarding_enabled          = true
    accelerated_networking_enabled = true

    ip_configuration {
      name                                   = "ipconfig-nva"
      primary                                = true
      subnet_id                              = azurerm_subnet.nva.id
      load_balancer_backend_address_pool_ids = [azurerm_lb_backend_address_pool.nva.id]
    }
  }

  depends_on = [
    azurerm_lb_rule.ha_ports,
    azurerm_subnet_network_security_group_association.nva,
  ]
}

# =============================================================================
# 6. AKS Automatic cluster (BYO VNet, CNI Overlay)
# =============================================================================
resource "azurerm_user_assigned_identity" "aks" {
  name                = "id-${var.name}-aks"
  location            = var.location
  resource_group_name = var.resource_group_name
}

resource "azurerm_role_assignment" "aks_vnet" {
  scope                = azurerm_virtual_network.aks.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks.principal_id
}

resource "azurerm_role_assignment" "aks_rt" {
  scope                = azurerm_route_table.aks.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks.principal_id
}

# Created with azapi: azurerm_kubernetes_automatic_cluster doesn't expose networkProfile.outboundType,
# and AKS Automatic rejects changing it after creation while node auto-provisioning is Auto
# (OperationNotAllowed), so userDefinedRouting must be in the create request.
resource "azapi_resource" "aks" {
  type                      = "Microsoft.ContainerService/managedClusters@2026-07-01"
  name                      = "aks-${var.name}"
  parent_id                 = local.resource_group_id
  location                  = var.location
  schema_validation_enabled = false

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks.id]
  }

  body = {
    sku = {
      name = "Automatic"
      tier = "Standard"
    }
    properties = {
      # API server VNet integration; private = internal LB IP in snet-aks-api, no public FQDN.
      apiServerAccessProfile = merge(
        {
          subnetId                       = azurerm_subnet.aks_api.id
          enablePrivateCluster           = var.private_cluster
          enablePrivateClusterPublicFQDN = false
        },
        var.private_cluster ? { privateDNSZone = "system" } : {},
      )
      hostedSystemProfile = {
        enabled            = true
        systemNodeSubnetId = azurerm_subnet.aks_system.id
        nodeSubnetId       = azurerm_subnet.aks_user.id
      }
      # Private: every node/pod flow follows the subnet route table (0.0.0.0/0 -> transit).
      networkProfile = {
        outboundType = var.private_cluster ? "userDefinedRouting" : "loadBalancer"
      }
      # Lets containerd/kubelet verify a Nexus cert issued by a private CA.
      # The API stores base64(PEM); LF line endings only.
      securityProfile = length(var.custom_ca_trust_certificates) > 0 ? {
        customCATrustCertificates = [for pem in var.custom_ca_trust_certificates : base64encode(replace(pem, "\r\n", "\n"))]
      } : null
    }
  }

  response_export_values = ["properties.privateFQDN", "properties.fqdn"]

  timeouts {
    create = "90m"
    update = "90m"
    delete = "90m"
  }

  depends_on = [
    azurerm_role_assignment.aks_vnet,
    azurerm_role_assignment.aks_rt,
    azurerm_subnet_nat_gateway_association.aks_system,
    azurerm_subnet_nat_gateway_association.aks_user,
    azurerm_subnet_route_table_association.aks_system,
    azurerm_subnet_route_table_association.aks_user,
    # Nodes bootstrap through the NVA: its SNAT must be in place first.
    azurerm_lb_rule.ha_ports,
    azurerm_linux_virtual_machine_scale_set.nva,
    azurerm_virtual_network_peering.aks_to_extra,
    azurerm_virtual_network_peering.extra_to_aks,
  ]
}

resource "azurerm_role_assignment" "aks_admin" {
  scope                = azapi_resource.aks.id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id         = var.admin_principal_id
}


# =============================================================================
# 7. PoC only: Azure Bastion + jump VM to reach the private API server.
# Its IP sits in the reused, non-routable internal range, so it is reachable only from inside
# this VNet. The jump VM has no public IP: the e2e script opens a Bastion native-client tunnel
# to its SSH port, then an SSH local forward to the API server. (Bastion IP-based tunnels
# only allow ports 22/3389, so they can't target the API server's 443 directly.)
# In production use in-VNet agents or `az aks command invoke` instead.
# =============================================================================
locals {
  bastion = var.private_cluster && var.create_bastion ? 1 : 0
}

resource "azurerm_subnet" "bastion" {
  count                = local.bastion
  name                 = "AzureBastionSubnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.aks.name
  address_prefixes     = [local.bastion_subnet_cidr]
}

resource "azurerm_public_ip" "bastion" {
  count               = local.bastion
  name                = "pip-${var.name}-bastion"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_bastion_host" "aks" {
  count               = local.bastion
  name                = "bas-${var.name}-aks"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "Standard"
  ip_connect_enabled  = true
  tunneling_enabled   = true

  ip_configuration {
    name                 = "bastion"
    subnet_id            = azurerm_subnet.bastion[0].id
    public_ip_address_id = azurerm_public_ip.bastion[0].id
  }
}

resource "azurerm_subnet" "jumpbox" {
  count                = local.bastion
  name                 = "snet-jumpbox"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.aks.name
  address_prefixes     = [local.jumpbox_subnet_cidr]
}

resource "azurerm_network_security_group" "jumpbox" {
  count               = local.bastion
  name                = "nsg-${var.name}-jumpbox"
  location            = var.location
  resource_group_name = var.resource_group_name

  security_rule {
    name                       = "Allow-SSH-From-Bastion"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = local.bastion_subnet_cidr
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Deny-Other-Inbound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "jumpbox" {
  count                     = local.bastion
  subnet_id                 = azurerm_subnet.jumpbox[0].id
  network_security_group_id = azurerm_network_security_group.jumpbox[0].id
}

resource "azurerm_network_interface" "jumpbox" {
  count               = local.bastion
  name                = "nic-${var.name}-jumpbox"
  location            = var.location
  resource_group_name = var.resource_group_name

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.jumpbox[0].id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "jumpbox" {
  count                 = local.bastion
  name                  = "vm-${var.name}-jumpbox"
  location              = var.location
  resource_group_name   = var.resource_group_name
  size                  = "Standard_D2s_v4"
  admin_username        = "azureuser"
  network_interface_ids = [azurerm_network_interface.jumpbox[0].id]

  admin_ssh_key {
    username   = "azureuser"
    public_key = var.ssh_public_key
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  os_disk {
    storage_account_type = "StandardSSD_LRS"
    caching              = "ReadWrite"
  }
}
