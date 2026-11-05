# AKS Automatic Custom VNet with Azure Virtual WAN & VMSS IP Masquerade

This repository provisions an **AKS Automatic** cluster inside an isolated custom Virtual Network (`vnet-aks-automatic`, `100.64.0.0/16`) and connects its workloads across an **Azure Virtual WAN Hub** (`vhub-central`) to a service inside a remote Virtual Network (`vnet-remote-services`, `10.200.0.0/16`) **without advertising the AKS `/16` or `/24` user node subnet to Virtual WAN**.

## Architecture Overview

```
+-----------------------------------------------------------------------------------+
| vnet-aks-automatic (Address space: 100.64.0.0/16 [Isolated CGNAT Space])          |
| (NEVER attached to Virtual WAN Hub - Reusable across multiple AKS clusters)       |
|                                                                                   |
|  +----------------------------------------+   +--------------------------------+  |
|  | snet-aks-user-nodes (100.64.1.0/24)    |   | snet-aks-system (100.64.0.64/26|  |
|  |                                        |   | snet-aks-api    (100.64.0.0/28)|  |
|  |  [ Test Job Pod ]                      |   +--------------------------------+  |
|  |         |                              |                                       |
|  |         | UDR: 10.200.0.0/16           |                                       |
|  |         | Next-hop: 10.100.0.4 (ILB)   |                                       |
|  +---------|------------------------------+                                       |
+------------|----------------------------------------------------------------------+
             |
             | Local VNet Peering (vnet-aks-automatic <-> vnet-nat-transit)
             v
+-----------------------------------------------------------------------------------+
| vnet-nat-transit (Address space: 10.100.0.0/28)                                   |
|                                                                                   |
|  +-----------------------------------------------------------------------------+  |
|  | snet-nat-masquerade (10.100.0.0/28)                                         |  |
|  |                                                                             |  |
|  |  [ Internal Standard LB (HA Ports + Floating IP): 10.100.0.4 ]              |  |
|  |         |                                                                   |  |
|  |         v                                                                   |  |
|  |  [ Linux VMSS (vmss-ip-masquerade) ]                                        |  |
|  |    - NIC IP Forwarding = enabled                                            |  |
|  |    - sysctl net.ipv4.ip_forward = 1, send_redirects = 0                     |  |
|  |    - iptables POSTROUTING MASQUERADE (-> 10.100.0.x)                        |  |
|  +-----------------------------------------------------------------------------+  |
+-----------------------------------------|-----------------------------------------+
                                          |
                                          | azurerm_virtual_hub_connection
                                          | (Only 10.100.0.0/28 is advertised to vWAN)
                                          v
+-----------------------------------------------------------------------------------+
| Azure Virtual WAN (vwan-enterprise)                                               |
|  +-----------------------------------------------------------------------------+  |
|  | Virtual Hub: vhub-central (10.50.0.0/24)                                    |  |
|  |  - Learned Spoke Routes: 10.100.0.0/28, 10.200.0.0/16                       |  |
|  |  - Zero knowledge of 100.64.0.0/16!                                         |  |
|  +-----------------------------------------------------------------------------+  |
+-----------------------------------------|-----------------------------------------+
                                          |
                                          | azurerm_virtual_hub_connection
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

### Why Use a Dedicated `/28` NAT Transit VNet with Azure Virtual WAN?

Unlike direct VNet peering, **Azure Virtual WAN (`azurerm_virtual_hub_connection`) does not support Subnet Peering**—attaching a VNet to a Virtual Hub automatically advertises **all** address spaces on that VNet into the Virtual Hub router and rejects any overlapping CIDR blocks across spokes.

By placing the IP Masquerade VMSS and Internal Load Balancer inside a dedicated `/28` Transit Spoke VNet (`vnet-nat-transit`, `10.100.0.0/28`):
1. **`vnet-aks-automatic` (`100.64.0.0/16`) is never connected to Virtual WAN**: Multiple AKS Automatic clusters can all use the exact same `100.64.0.0/16` address space (including the required `/24` user node subnet `100.64.1.0/24`).
2. **Cross-VNet UDR Next-Hop**: `vnet-aks-automatic` peers locally with `vnet-nat-transit`, and its Route Table (`rt-aks-to-remote-vnet`) points `10.200.0.0/16` to the Internal Load Balancer (`10.100.0.4`) in `vnet-nat-transit`.
3. **Full Virtual WAN Hub Transit**: Because `vnet-nat-transit` (`10.100.0.0/28`) and `vnet-remote-services` (`10.200.0.0/16`) are both connected to `vhub-central` via `azurerm_virtual_hub_connection`, the Virtual Hub router automatically exchanges routes between `10.100.0.0/28` and `10.200.0.0/16`.

---

## Deployment & Verification Steps

### 1. Provision the Infrastructure
> **Note**: Provisioning an Azure Virtual WAN Hub (`azurerm_virtual_hub`) typically takes ~15–30 minutes in Azure as the underlying hub router infrastructure is allocated.
```bash
terraform init
terraform apply
```

### 2. Run the Test Job in AKS Automatic
Once `terraform apply` completes, re-run the Kubernetes test job:
```bash
kubectl replace --force -f k8s/test-peered-api-job.yaml
kubectl wait --for=condition=complete --timeout=180s job/test-peered-api-connectivity
kubectl logs job/test-peered-api-connectivity
```
