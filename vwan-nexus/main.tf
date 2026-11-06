resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
}

resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

locals {
  nexus_fqdn = "${var.nexus_hostname}.${var.private_dns_zone_name}"

  # Everything AKS reaches through its transit NVA -> vWAN hub. Public clusters send internet/MCR to their
  # NAT gateway; private clusters send that through the transit and the hub's default route as well.
  private_destinations = distinct(concat(
    [var.nexus_cidr],
    var.onprem_cidrs,
    var.create_onprem_sim ? [var.onprem_sim_cidr] : [],
  ))

  # Source ranges Nexus and on-prem accept: every transit /28, plus the Azure Firewall subnet under test.
  snat_source_cidrs = concat(
    [for e in values(var.environments) : e.transit_cidr],
    var.create_azfw_test ? [local.azfw_subnet] : [],
  )
}

# =============================================================================
# 0. Private CA + Nexus server certificate (simulates an enterprise private PKI)
# =============================================================================
resource "tls_private_key" "ca" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P384"
}

resource "tls_self_signed_cert" "ca" {
  private_key_pem       = tls_private_key.ca.private_key_pem
  is_ca_certificate     = true
  validity_period_hours = 24 * 365
  allowed_uses          = ["cert_signing", "crl_signing", "digital_signature"]

  subject {
    common_name  = "PoC Private Root CA"
    organization = "aks-vwan-nexus PoC"
  }
}

resource "tls_private_key" "nexus" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_cert_request" "nexus" {
  private_key_pem = tls_private_key.nexus.private_key_pem
  dns_names       = [local.nexus_fqdn]
  ip_addresses    = [var.nexus_ip]

  subject {
    common_name  = local.nexus_fqdn
    organization = "aks-vwan-nexus PoC"
  }
}

resource "tls_locally_signed_cert" "nexus" {
  cert_request_pem      = tls_cert_request.nexus.cert_request_pem
  ca_private_key_pem    = tls_private_key.ca.private_key_pem
  ca_cert_pem           = tls_self_signed_cert.ca.cert_pem
  validity_period_hours = 24 * 180
  allowed_uses          = ["digital_signature", "key_encipherment", "server_auth"]
}

resource "local_file" "ca_cert" {
  filename        = "${path.module}/ca.crt"
  content         = tls_self_signed_cert.ca.cert_pem
  file_permission = "0644"
}

# =============================================================================
# 1. Virtual WAN + hub (PoC only; set existing_virtual_hub_id to use the real PROD hub)
# =============================================================================
resource "azurerm_virtual_wan" "vwan" {
  count               = var.existing_virtual_hub_id == null ? 1 : 0
  name                = "vwan-poc"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  type                = "Standard"
}

resource "azurerm_virtual_hub" "hub" {
  count               = var.existing_virtual_hub_id == null ? 1 : 0
  name                = "vhub-poc-${var.location}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  virtual_wan_id      = azurerm_virtual_wan.vwan[0].id
  address_prefix      = var.hub_address_prefix
  sku                 = "Standard"

  lifecycle {
    precondition {
      condition     = !var.private_clusters || var.create_hub_firewall
      error_message = "private_clusters forces egress to the hub's default route; the PoC hub has none unless create_hub_firewall = true."
    }
  }
}

locals {
  virtual_hub_id = var.existing_virtual_hub_id != null ? var.existing_virtual_hub_id : azurerm_virtual_hub.hub[0].id
}

# =============================================================================
# 2. Nexus stand-in ("AKS Shared Infra" spoke connected to the hub)
# =============================================================================
resource "random_password" "nexus_admin" {
  count   = var.create_nexus_standin ? 1 : 0
  length  = 24
  special = false
}

resource "azurerm_virtual_network" "nexus" {
  count               = var.create_nexus_standin ? 1 : 0
  name                = "vnet-shared-nexus"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = [var.nexus_cidr]
}

resource "azurerm_subnet" "nexus" {
  count                = var.create_nexus_standin ? 1 : 0
  name                 = "snet-nexus"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.nexus[0].name
  address_prefixes     = [var.nexus_cidr]
}

resource "azurerm_virtual_hub_connection" "nexus" {
  count                     = var.create_nexus_standin ? 1 : 0
  name                      = "conn-shared-nexus"
  virtual_hub_id            = local.virtual_hub_id
  remote_virtual_network_id = azurerm_virtual_network.nexus[0].id
  internet_security_enabled = false
}

# Outbound internet for apt + docker pull of the Nexus image.
resource "azurerm_public_ip" "nexus_natgw" {
  count               = var.create_nexus_standin ? 1 : 0
  name                = "pip-nexus-natgw"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_nat_gateway" "nexus" {
  count               = var.create_nexus_standin ? 1 : 0
  name                = "ngw-nexus"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku_name            = "Standard"
}

resource "azurerm_nat_gateway_public_ip_association" "nexus" {
  count                = var.create_nexus_standin ? 1 : 0
  nat_gateway_id       = azurerm_nat_gateway.nexus[0].id
  public_ip_address_id = azurerm_public_ip.nexus_natgw[0].id
}

resource "azurerm_subnet_nat_gateway_association" "nexus" {
  count          = var.create_nexus_standin ? 1 : 0
  subnet_id      = azurerm_subnet.nexus[0].id
  nat_gateway_id = azurerm_nat_gateway.nexus[0].id
}

# Only the per-environment transit /28s may reach Nexus. A successful pull from AKS therefore
# proves the traffic was SNAT'd by the transit NVA and crossed the vWAN hub.
resource "azurerm_network_security_group" "nexus" {
  count               = var.create_nexus_standin ? 1 : 0
  name                = "nsg-nexus"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name                       = "Allow-Transit-To-Nexus"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
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

resource "azurerm_subnet_network_security_group_association" "nexus" {
  count                     = var.create_nexus_standin ? 1 : 0
  subnet_id                 = azurerm_subnet.nexus[0].id
  network_security_group_id = azurerm_network_security_group.nexus[0].id
}

resource "azurerm_network_interface" "nexus" {
  count               = var.create_nexus_standin ? 1 : 0
  name                = "nic-nexus"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "ipconfig-nexus"
    subnet_id                     = azurerm_subnet.nexus[0].id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.nexus_ip
  }
}

resource "azurerm_linux_virtual_machine" "nexus" {
  count                 = var.create_nexus_standin ? 1 : 0
  name                  = "vm-nexus"
  resource_group_name   = azurerm_resource_group.rg.name
  location              = azurerm_resource_group.rg.location
  size                  = var.nexus_vm_sku
  admin_username        = "azureuser"
  network_interface_ids = [azurerm_network_interface.nexus[0].id]

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
    disk_size_gb         = 128
  }

  custom_data = base64encode(templatefile("${path.module}/nexus-cloud-init.yaml.tftpl", {
    admin_password = random_password.nexus_admin[0].result
    docker_port    = var.nexus_docker_port
    image          = var.nexus_image
    fqdn           = local.nexus_fqdn
    tls_cert       = "${tls_locally_signed_cert.nexus.cert_pem}${tls_self_signed_cert.ca.cert_pem}"
    tls_key        = tls_private_key.nexus.private_key_pem
  }))

  depends_on = [
    azurerm_subnet_nat_gateway_association.nexus,
    azurerm_subnet_network_security_group_association.nexus,
  ]
}

# =============================================================================
# 3. AKS Automatic environments (transit /28 on vWAN + non-routable AKS VNet)
# =============================================================================
module "env" {
  source   = "./modules/aks-env"
  for_each = var.environments

  name                = each.key
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  virtual_hub_id      = local.virtual_hub_id
  transit_cidr        = each.value.transit_cidr
  internal_cidr       = each.value.internal_cidr
  destination_cidrs   = local.private_destinations
  ssh_public_key      = tls_private_key.ssh.public_key_openssh
  nva_vmss_sku        = var.nva_vmss_sku
  nva_vmss_instances  = var.nva_vmss_instances
  nva_zones           = var.nva_zones
  admin_principal_id  = data.azurerm_client_config.current.object_id

  next_hop_override = var.create_azfw_test && each.key == var.azfw_test_env ? local.azfw_private_ip : null
  # Peered from inside the module so the cluster (which bootstraps through its next hop) waits for it.
  extra_peer_vnet = var.create_azfw_test && each.key == var.azfw_test_env ? {
    id   = azurerm_virtual_network.azfw[0].id
    name = azurerm_virtual_network.azfw[0].name
  } : null

  private_cluster = var.private_clusters
  create_bastion  = var.create_bastion

  custom_ca_trust_certificates = var.enable_custom_ca_trust ? [tls_self_signed_cert.ca.cert_pem] : []

  # The transit connection only propagates the hub's default route once routing intent exists.
  depends_on = [azurerm_virtual_hub_routing_intent.hub]
}

# =============================================================================
# 4. Private DNS for the Nexus hostname, linked to every AKS VNet
# =============================================================================
resource "azurerm_private_dns_zone" "poc" {
  name                = var.private_dns_zone_name
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_a_record" "nexus" {
  name                = var.nexus_hostname
  private_dns_zone_id = azurerm_private_dns_zone.poc.id
  ttl                 = 300
  records             = [var.nexus_ip]
}

resource "azurerm_private_dns_zone_virtual_network_link" "aks" {
  for_each            = module.env
  name                = "link-${each.key}-aks"
  private_dns_zone_id = azurerm_private_dns_zone.poc.id
  virtual_network_id  = each.value.aks_vnet_id
}

# =============================================================================
# 5. Test manifests (no secrets rendered; credentials come from K8s Secrets)
# =============================================================================
resource "local_file" "nexus_pull_test" {
  filename = "${path.module}/k8s/nexus-pull-test.yaml"
  content = templatefile("${path.module}/k8s/nexus-pull-test.yaml.tftpl", {
    nexus_registry = local.nexus_fqdn
    seed_image     = var.seed_image
  })
}

resource "local_file" "kubelet_pull_test" {
  filename = "${path.module}/k8s/kubelet-pull-test.yaml"
  content = templatefile("${path.module}/k8s/kubelet-pull-test.yaml.tftpl", {
    image = "${local.nexus_fqdn}/poc/seed:1"
  })
}
