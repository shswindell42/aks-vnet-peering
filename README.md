# AKS Automatic Custom VNet with Subnet Peering & VMSS IP Masquerade

This repository provisions an **AKS Automatic** cluster inside a custom Virtual Network (`vnet-aks-automatic`) and connects its workloads to a service inside a peered Virtual Network (`vnet-remote-services`) **without peering the `/24` user node subnet** required by AKS Automatic.

> **Using Azure Virtual WAN?** A vWAN hub connection is whole-VNet only, so subnet peering can't be used toward a hub. See [`vwan-nexus/`](vwan-nexus/README.md) for the vWAN variant: a per-environment transit `/28`, with AKS VNets that reuse non-routable space and reach Nexus through the hub ([diagram](vwan-nexus/docs/architecture.svg)).

## Architecture Overview

```
+-----------------------------------------------------------------------------------+
| vnet-aks-automatic (Address spaces: 100.64.0.0/16 [Non-peered], 10.100.0.0/28)    |
|                                                                                   |
|  +----------------------------------------+   +--------------------------------+  |
|  | snet-aks-user-nodes (100.64.1.0/24)    |   | snet-aks-system (100.64.0.64/26|  |
|  | (NOT Peered - Reusable CGNAT Space)    |   | snet-aks-api    (100.64.0.0/28)|  |
|  |                                        |   +--------------------------------+  |
|  |  [ Test Job Pod ]                      |                                       |
|  |         |                              |                                       |
|  |         | UDR: 10.200.0.0/16           |                                       |
|  |         | Next-hop: 10.100.0.4 (ILB)   |                                       |
|  +---------|------------------------------+                                       |
|            v                                                                      |
|  +-----------------------------------------------------------------------------+  |
|  | snet-nat-masquerade (10.100.0.0/28)  [ ONLY THIS SUBNET IS PEERED ]         |  |
|  |                                                                             |  |
|  |  [ Internal Standard LB (HA Ports): 10.100.0.4 ]                            |  |
|  |         |                                                                   |  |
|  |         v                                                                   |  |
|  |  [ Linux VMSS (vmss-ip-masquerade) ]                                        |  |
|  |    - NIC IP Forwarding = enabled                                            |  |
|  |    - sysctl net.ipv4.ip_forward = 1, send_redirects = 0                     |  |
|  |    - iptables POSTROUTING MASQUERADE (100.64.0.0/16 -> 10.100.0.x)          |  |
|  +-----------------------------------------------------------------------------+  |
+-----------------------------------------|-----------------------------------------+
                                          |
                                          | Azure VNet Subnet Peering
                                          | (peer_complete_virtual_networks_enabled = false)
                                          | Only 10.100.0.0/28 <-> 10.200.1.0/24
                                          v
+-----------------------------------------------------------------------------------+
| vnet-remote-services (Address space: 10.200.0.0/16)                               |
|                                                                                   |
|  +-----------------------------------------------------------------------------+  |
|  | snet-remote-api (10.200.1.0/24)                                             |  |
|  |                                                                             |  |
|  |  [ Target API VM: 10.200.1.10:8080 ]                                        |  |
|  |    - NSG only allows TCP 8080 from 10.100.0.0/28                            |  |
|  |    - Echoes JSON with `client_ip_seen_by_api` (verifies 10.100.0.x SNAT)    |  |
|  +-----------------------------------------------------------------------------+  |
+-----------------------------------------------------------------------------------+
```

### How It Works

1. **Dual Address Space & Non-Peered AKS Subnets**:
   - `vnet-aks-automatic` is configured with two address spaces:
     - `100.64.0.0/16` (non-peered CGNAT space) for the AKS API server (`100.64.0.0/28`), system nodes (`100.64.0.64/26`), and the `/24` user node subnet (`100.64.1.0/24`).
     - `10.100.0.0/28` (a tiny 16-IP routable block) dedicated exclusively to `snet-nat-masquerade`.
2. **Azure Subnet Peering**:
   - Both `azurerm_virtual_network_peering` resources set `peer_complete_virtual_networks_enabled = false` and explicitly peer **only** `snet-nat-masquerade` (`10.100.0.0/28`) with `snet-remote-api` (`10.200.1.0/24`).
   - The remote VNet never learns a route to `100.64.0.0/16`, allowing multiple AKS Automatic clusters to reuse the exact same `100.64.0.0/16` space.
3. **UDR + Internal Load Balancer + IP Masquerade VMSS**:
   - A Route Table (`rt-aks-to-remote-vnet`) attached to `snet-aks-user-nodes` and `snet-aks-system` directs traffic for `10.200.0.0/16` to the Internal Standard Load Balancer (`10.100.0.4`).
   - The VMSS instances (`vmss-ip-masquerade`) have Azure NIC `ip_forwarding_enabled = true`, Linux kernel IP forwarding enabled (`send_redirects = 0` to prevent ICMP redirect loops on a single NIC), and an `iptables` `MASQUERADE` rule rewriting source IPs from `100.64.0.0/16` to the VMSS instance's `10.100.0.x` IP.

---

## Prerequisites

1. **Enable Azure Subnet Peering on your Subscription** (one-time registration):
   ```bash
   az feature register --namespace Microsoft.Network --name AllowSubnetPeering
   # Wait until status is "Registered":
   az feature show --namespace Microsoft.Network --name AllowSubnetPeering --query "properties.state" -o tsv
   # Propagate the feature registration:
   az provider register --namespace Microsoft.Network
   ```
2. **Tools**:
   - Terraform `>= 1.5.0` (with `hashicorp/azurerm >= 4.81.0` for `azurerm_kubernetes_automatic_cluster`)
   - Azure CLI (`az`)
   - `kubectl` and `kubelogin`

---

## Deployment & Verification Steps

### 1. Provision the Infrastructure
```bash
terraform init
terraform apply
```

### 2. Run the Test Job in AKS Automatic
Once `terraform apply` completes, authenticate to the cluster and run the Kubernetes test job:
```bash
az aks get-credentials \
  --resource-group $(terraform output -raw resource_group_name) \
  --name $(terraform output -raw aks_cluster_name) \
  --overwrite-existing

kubectl apply -f k8s/test-peered-api-job.yaml
kubectl wait --for=condition=complete --timeout=180s job/test-peered-api-connectivity
kubectl logs job/test-peered-api-connectivity
```

### Expected Output from the Test Job
The pod runs inside the non-peered `100.64.1.0/24` node subnet, reaches `http://10.200.1.10:8080/health` in the peered VNet, and verifies that the API server sees a `10.100.0.x` NAT VMSS IP:
```text
==========================================================
AKS Automatic -> VMSS IP Masquerade -> Peered VNet Test
==========================================================
Pod IP (Overlay):        10.244.x.x
AKS Node IP (Non-peered): 100.64.1.x
Target Peered API URL:   http://10.200.1.10:8080/health
----------------------------------------------------------
Sending HTTP GET request to peered VNet API...
Response received from Peered VNet API:
{
  "status": "ok",
  "message": "Hello from the peered VNet API!",
  "client_ip_seen_by_api": "10.100.0.5",
  "client_port_seen_by_api": 48214,
  "api_server_hostname": "vm-remote-api",
  "api_server_ip": "10.200.1.10",
  "path": "/health",
  "timestamp": "2026-11-02T19:45:00.000000+00:00"
}
----------------------------------------------------------
SUCCESS: Traffic was masqueraded by the NAT VMSS (10.100.0.x)!
```

