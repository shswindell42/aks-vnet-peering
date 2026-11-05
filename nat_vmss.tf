# =============================================================================
# SSH Key Pair for VMSS & Test API VM
# =============================================================================
resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# =============================================================================
# Internal Standard Load Balancer (HA Ports) in NAT Masquerade Subnet
# =============================================================================
resource "azurerm_lb" "nat_ilb" {
  name                = "ilb-nat-masquerade"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "Standard"

  frontend_ip_configuration {
    name                          = "fe-nat-ilb"
    subnet_id                     = azurerm_subnet.nat_masquerade.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.nat_lb_private_ip
  }
}

resource "azurerm_lb_backend_address_pool" "nat_pool" {
  loadbalancer_id = azurerm_lb.nat_ilb.id
  name            = "bepool-nat-vmss"
}

resource "azurerm_lb_probe" "nat_probe" {
  loadbalancer_id     = azurerm_lb.nat_ilb.id
  name                = "probe-ssh-22"
  protocol            = "Tcp"
  port                = 22
  interval_in_seconds = 5
  number_of_probes    = 2
}

resource "azurerm_lb_rule" "ha_ports" {
  loadbalancer_id                = azurerm_lb.nat_ilb.id
  name                           = "rule-ha-ports-all"
  protocol                       = "All"
  frontend_port                  = 0
  backend_port                   = 0
  frontend_ip_configuration_name = "fe-nat-ilb"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.nat_pool.id]
  probe_id                       = azurerm_lb_probe.nat_probe.id
  floating_ip_enabled            = true
  disable_outbound_snat          = true
}

# =============================================================================
# Network Security Group for NAT Masquerade Subnet
# =============================================================================
resource "azurerm_network_security_group" "nat_nsg" {
  name                = "nsg-nat-masquerade"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name                       = "Allow-AKS-Internal-Forwarding"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-AzureLoadBalancer"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "nat_nsg_assoc" {
  subnet_id                 = azurerm_subnet.nat_masquerade.id
  network_security_group_id = azurerm_network_security_group.nat_nsg.id
}

# =============================================================================
# Linux VMSS for IP Masquerade (SNAT)
# =============================================================================
locals {
  nat_cloud_init = <<-EOT
    #cloud-config
    write_files:
      - path: /etc/sysctl.d/99-ipforward.conf
        content: |
          net.ipv4.ip_forward=1
          net.ipv4.conf.all.send_redirects=0
          net.ipv4.conf.default.send_redirects=0
          net.ipv4.conf.eth0.send_redirects=0
      - path: /usr/local/sbin/setup-nat-masquerade.sh
        permissions: '0755'
        content: |
          #!/bin/bash
          set -euo pipefail
          sysctl --system
          PRIMARY_IF=$(ip route show default | awk '{print $5}' | head -n1)
          sysctl -w "net.ipv4.conf.$${PRIMARY_IF}.send_redirects=0"
          iptables -t nat -C POSTROUTING -d ${var.remote_vnet_cidr} -o "$${PRIMARY_IF}" -j MASQUERADE 2>/dev/null || \
            iptables -t nat -A POSTROUTING -d ${var.remote_vnet_cidr} -o "$${PRIMARY_IF}" -j MASQUERADE
          iptables -C FORWARD -d ${var.remote_vnet_cidr} -j ACCEPT 2>/dev/null || \
            iptables -A FORWARD -d ${var.remote_vnet_cidr} -j ACCEPT
          iptables -C FORWARD -s ${var.remote_vnet_cidr} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
            iptables -A FORWARD -s ${var.remote_vnet_cidr} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
      - path: /etc/systemd/system/nat-masquerade.service
        content: |
          [Unit]
          Description=Configure IP Masquerade for AKS to Peered VNet
          After=network-online.target
          Wants=network-online.target

          [Service]
          Type=oneshot
          ExecStart=/usr/local/sbin/setup-nat-masquerade.sh
          RemainAfterExit=yes

          [Install]
          WantedBy=multi-user.target
    runcmd:
      - systemctl daemon-reload
      - systemctl enable --now nat-masquerade.service
  EOT
}

resource "azurerm_linux_virtual_machine_scale_set" "nat_vmss" {
  name                = "vmss-ip-masquerade"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = var.nat_vmss_sku
  instances           = var.nat_vmss_instances
  admin_username      = "azureuser"
  upgrade_mode        = "Automatic"

  rolling_upgrade_policy {
    max_batch_instance_percent              = 50
    max_unhealthy_instance_percent          = 100
    max_unhealthy_upgraded_instance_percent = 100
    pause_time_between_batches              = "PT0S"
  }

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
    storage_account_type = "Standard_LRS"
    caching              = "ReadWrite"
  }

  custom_data = base64encode(local.nat_cloud_init)

  network_interface {
    name    = "nic-nat-vmss"
    primary = true

    # Crucial: Allow NIC to receive packets destined for the remote VNet
    ip_forwarding_enabled = true

    ip_configuration {
      name                                   = "ipconfig-nat"
      primary                                = true
      subnet_id                              = azurerm_subnet.nat_masquerade.id
      load_balancer_backend_address_pool_ids = [azurerm_lb_backend_address_pool.nat_pool.id]
    }
  }

  depends_on = [
    azurerm_lb_rule.ha_ports,
  ]
}

