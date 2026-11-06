#!/usr/bin/env bash
# shfmt -i 2 -ci -w
set -Eeuo pipefail

trap exit SIGINT SIGTERM

################################################################################
# AKS Automatic -> transit NVA -> vWAN hub -> Nexus (and on-prem): end-to-end test
#
# Proves, for one environment:
#   1. routing      the hub gives the transit VNet a route to Nexus, gives the
#                   Nexus spoke a route back to the transit /28, and NEVER
#                   learns the (reused, non-routable) AKS range.
#   2. nva          every NVA instance behind the ILB is healthy.
#   3. ca-trust     the private root CA is in the cluster's securityProfile.
#   4. pod-pull     a pod reaches Nexus over TLS (private CA), pushes and pulls.
#   5. kubelet-pull containerd pulls from Nexus using node-level CA trust.
#                   NAP nodes created before CA trust was set are not reimaged;
#                   with RECYCLE_NODES=true their NodeClaims are deleted and the
#                   pull is retried on fresh nodes.
#   6. egress       (only with private_clusters) the API server is private, the
#                   cluster uses userDefinedRouting, the transit VNet learns the
#                   hub's 0.0.0.0/0, and a pod's internet egress IP is the hub
#                   firewall's public IP.
#   7. onprem       (only with create_onprem_sim) the hub gives the transit VNet
#                   the on-prem prefix, on-prem learns the transit /28 but never
#                   the AKS range, and a pod reaches an on-prem server that sees
#                   an NVA transit IP as the client.
#
# Everything else is read from `terraform output` in TF_DIR. Private API servers are
# reached through Azure Bastion (create_bastion): a native-client tunnel to the jump VM's SSH
# port, then an SSH local forward to the API server.

################################################################################
# Default configuration
TF_DIR=${TF_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
ENV_NAME=${ENV_NAME:-dev}
KUBECONFIG=${KUBECONFIG:-${TF_DIR}/.kubeconfig-${ENV_NAME}}
NAMESPACE=${NAMESPACE:-default}
RECYCLE_NODES=${RECYCLE_NODES:-true}
POD_TIMEOUT=${POD_TIMEOUT:-900}
AKS_API_VERSION=${AKS_API_VERSION:-2026-07-01}
TUNNEL_PORT=${TUNNEL_PORT:-}
################################################################################
export KUBECONFIG

__usage="
    -x  action to be executed.

Possible verbs are:
    all            Run every test below in order.
    check-deps     Check required tools.
    setup          Fetch credentials; create nexus-cred, nexus-pull, nexus-ca.
    routing        Assert hub effective routes (Nexus in, AKS range never out).
    nva            Assert all NVA backends are healthy (ILB DipAvailability).
    ca-trust       Assert the private CA is set in securityProfile.
    pod-pull       Run the crane Job (TLS with private CA, push + pull, MB/s).
    kubelet-pull   Pull from Nexus via kubelet/containerd (node CA trust).
    egress         Assert private API server, userDefinedRouting, hub 0/0 on the
                   transit, and pod internet egress via the hub firewall.
    onprem         Assert routes to/from simulated on-prem and SNAT'd reachability.
    recycle-nodes  Delete all NAP NodeClaims so NAP provisions fresh nodes.
    nva-reimage    Reimage NVA instances one at a time (applies new custom_data,
                   e.g. after changing private destinations) and verify SNAT rules.
    cleanup        Delete the test Job/Pod (secrets and configmap are kept).

Environment variables (with defaults):
    TF_DIR=${TF_DIR}
    ENV_NAME=${ENV_NAME}
    KUBECONFIG=${KUBECONFIG}
    NAMESPACE=${NAMESPACE}
    RECYCLE_NODES=${RECYCLE_NODES}
    POD_TIMEOUT=${POD_TIMEOUT}
    AKS_API_VERSION=${AKS_API_VERSION}
    TUNNEL_PORT=${TUNNEL_PORT:-<16443 dev, 26443 qa, 36443 prod>}
"

usage() {
  echo "usage: ${0##*/} [options]"
  echo "${__usage/[[:space:]]/}"
  exit 1
}

print_header() {
  echo ""
  echo "AKS Automatic -> vWAN -> Nexus E2E test"
  echo "=========================================="
  echo ""
  echo "Terraform dir:   $TF_DIR"
  echo "Environment:     $ENV_NAME"
  echo "Kubeconfig:      $KUBECONFIG"
  echo "Recycle nodes:   $RECYCLE_NODES"
  echo ""
}

log() {
  echo "[$(date +"%r")] $*"
}

fail() {
  log "FAIL: $*"
  exit 1
}

check_dependencies() {
  log "Checking dependencies..."
  local _NEEDED="az terraform kubectl kubelogin jq ssh python3"
  local _DEP_FLAG=false

  for i in ${_NEEDED}; do
    if hash "$i" 2>/dev/null; then
      log "  $i: OK"
    else
      log "  $i: NOT FOUND"
      _DEP_FLAG=true
    fi
  done

  if [[ "${_DEP_FLAG}" == "true" ]]; then
    log "Dependencies missing. Please install them before proceeding"
    exit 1
  fi

  log "All dependencies satisfied"
}

tf_out() {
  terraform -chdir="$TF_DIR" output -raw "$1"
}

load_outputs() {
  local _env_json

  RESOURCE_GROUP=$(tf_out resource_group_name)
  HUB_ID=$(tf_out virtual_hub_id)
  NEXUS_CIDR=$(tf_out nexus_cidr)
  PRIVATE_DESTINATIONS=$(terraform -chdir="$TF_DIR" output -json private_destinations | jq -r '.[]')
  ONPREM_JSON=$(terraform -chdir="$TF_DIR" output -json onprem_sim)
  NEXUS_REGISTRY=$(tf_out nexus_registry)
  CA_FILE=$(tf_out ca_cert_file)
  _env_json=$(terraform -chdir="$TF_DIR" output -json environments | jq -e --arg e "$ENV_NAME" '.[$e]') ||
    fail "environment '$ENV_NAME' not found in terraform output"
  CLUSTER_NAME=$(jq -r .cluster_name <<<"$_env_json")
  TRANSIT_CIDR=$(jq -r .transit_cidr <<<"$_env_json")
  NVA_VMSS="vmss-${ENV_NAME}-nva"
  AKS_CIDR=$(jq -r .aks_internal_cidr <<<"$_env_json")
  PRIVATE_CLUSTER=$(jq -r .private_cluster <<<"$_env_json")
  API_FQDN=$(jq -r .api_server_fqdn <<<"$_env_json")
  BASTION_NAME=$(jq -r .bastion_name <<<"$_env_json")
  JUMPBOX_ID=$(jq -r .jumpbox_id <<<"$_env_json")
  # Relative paths in outputs are relative to TF_DIR.
  case "$CA_FILE" in
    /*) ;;
    *) CA_FILE="${TF_DIR}/${CA_FILE#./}" ;;
  esac
}

# Prefixes the hub programs for a hub VNet connection, one per line.
hub_routes() {
  local _conn=$1
  local _hub_rg _hub_name _conn_id

  _hub_rg=$(cut -d/ -f5 <<<"$HUB_ID")
  _hub_name=${HUB_ID##*/}
  _conn_id=$(az network vhub connection show -g "$_hub_rg" --vhub-name "$_hub_name" -n "$_conn" --query id -o tsv)
  az network vhub get-effective-routes -g "$_hub_rg" -n "$_hub_name" \
    --resource-type HubVirtualNetworkConnection --resource-id "$_conn_id" \
    --query 'value[].addressPrefixes[]' -o tsv 2>/dev/null
}

# Private API server: Bastion tunnel (127.0.0.1:TUNNEL_PORT+1 -> jump VM :22), then an SSH local
# forward (127.0.0.1:TUNNEL_PORT -> API server IP :443). The kubeconfig still verifies the API
# server certificate against its private FQDN.
tunnel_port() {
  if [[ -n "$TUNNEL_PORT" ]]; then
    echo "$TUNNEL_PORT"
    return
  fi
  case "$ENV_NAME" in
    dev) echo 16443 ;;
    qa) echo 26443 ;;
    prod) echo 36443 ;;
    *) echo 46443 ;;
  esac
}

# SSH key and control socket live outside TF_DIR (some filesystems, e.g. exFAT, have no Unix sockets).
tunnel_dir() {
  local _d="${TMPDIR:-/tmp}/aks-vwan-e2e-${ENV_NAME}"
  (umask 077 && mkdir -p "$_d")
  echo "$_d"
}

port_open() {
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

wait_port() {
  local _port=$1 _pid=$2
  for _ in $(seq 1 60); do
    port_open "$_port" && return 0
    kill -0 "$_pid" 2>/dev/null || return 1
    sleep 2
  done
  return 1
}

ensure_tunnel() {
  [[ "${PRIVATE_CLUSTER:-}" == "true" ]] || return 0
  local _port _ssh_port _pidf _logf _key _sock _node_rg _api_ip _pid
  _port=$(tunnel_port)
  _ssh_port=$((_port + 1))
  _pidf="$(tunnel_dir)/bastion.pid"
  _logf="$(tunnel_dir)/bastion.log"
  _key="$(tunnel_dir)/ssh-key"
  _sock="$(tunnel_dir)/ssh.sock"
  if ssh -S "$_sock" -O check jumpbox 2>/dev/null && port_open "$_port"; then
    return 0
  fi
  [[ -n "$BASTION_NAME" && "$BASTION_NAME" != "null" ]] ||
    fail "private cluster but no Bastion; apply with -var create_bastion=true"

  if ! { [[ -s "$_pidf" ]] && kill -0 "$(cat "$_pidf")" 2>/dev/null && port_open "$_ssh_port"; }; then
    log "Opening Bastion tunnel 127.0.0.1:${_ssh_port} -> ${JUMPBOX_ID##*/}:22 via ${BASTION_NAME}"
    AZURE_EXTENSION_USE_DYNAMIC_INSTALL=yes_without_prompt \
      nohup az network bastion tunnel -g "$RESOURCE_GROUP" -n "$BASTION_NAME" \
      --target-resource-id "$JUMPBOX_ID" --resource-port 22 --port "$_ssh_port" >"$_logf" 2>&1 &
    _pid=$!
    echo "$_pid" >"$_pidf"
    wait_port "$_ssh_port" "$_pid" || {
      cat "$_logf" >&2
      fail "could not open the Bastion tunnel"
    }
  fi

  _node_rg=$(az aks show -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --query nodeResourceGroup -o tsv)
  _api_ip=$(az network lb show -g "$_node_rg" -n kube-apiserver \
    --query 'frontendIPConfigurations[0].privateIPAddress' -o tsv)
  [[ -n "$_api_ip" ]] || fail "could not find the API server internal load balancer IP"
  (umask 077 && tf_out ssh_private_key >"$_key")
  log "Opening SSH forward 127.0.0.1:${_port} -> ${_api_ip}:443 (${API_FQDN})"
  ssh -i "$_key" -p "$_ssh_port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 \
    -M -S "$_sock" -f -N -L "127.0.0.1:${_port}:${_api_ip}:443" azureuser@127.0.0.1 ||
    fail "could not open the SSH forward through the jump VM"
}

close_tunnel() {
  local _d
  _d=$(tunnel_dir)
  ssh -S "$_d/ssh.sock" -O exit jumpbox 2>/dev/null || true
  [[ -s "$_d/bastion.pid" ]] && kill "$(cat "$_d/bastion.pid")" 2>/dev/null
  rm -rf "$_d"
}

do_setup() {
  load_outputs
  log "Fetching credentials for $CLUSTER_NAME into $KUBECONFIG"
  (umask 077 && : >>"$KUBECONFIG")
  az aks get-credentials -g "$RESOURCE_GROUP" -n "$CLUSTER_NAME" --file "$KUBECONFIG" --overwrite-existing -o none
  kubelogin convert-kubeconfig -l azurecli
  if [[ "$PRIVATE_CLUSTER" == "true" ]]; then
    kubectl config set-cluster "$CLUSTER_NAME" --server="https://127.0.0.1:$(tunnel_port)" \
      --tls-server-name="$API_FQDN" >/dev/null
    ensure_tunnel
  fi

  # The Nexus password only travels through pipes, never argv.
  log "Creating secret nexus-cred, dockerconfigjson secret nexus-pull, configmap nexus-ca"
  tf_out nexus_admin_password |
    kubectl -n "$NAMESPACE" create secret generic nexus-cred --from-file=password=/dev/stdin \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  tf_out nexus_admin_password |
    jq -Rr --arg r "$NEXUS_REGISTRY" \
      '{auths: {($r): {username: "admin", password: ., auth: ("admin:" + . | @base64)}}}' |
    kubectl -n "$NAMESPACE" create secret generic nexus-pull --type=kubernetes.io/dockerconfigjson \
      --from-file=.dockerconfigjson=/dev/stdin --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n "$NAMESPACE" create configmap nexus-ca --from-file=ca.crt="$CA_FILE" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  log "Setup completed"
}

do_routing() {
  load_outputs
  local _transit_routes _nexus_routes

  _transit_routes=$(hub_routes "conn-${ENV_NAME}-transit")
  log "Hub routes on conn-${ENV_NAME}-transit: $(tr '\n' ' ' <<<"$_transit_routes")"
  grep -qxF "$NEXUS_CIDR" <<<"$_transit_routes" || fail "transit VNet has no hub route to Nexus $NEXUS_CIDR"

  _nexus_routes=$(hub_routes conn-shared-nexus)
  log "Hub routes on conn-shared-nexus: $(tr '\n' ' ' <<<"$_nexus_routes")"
  grep -qxF "$TRANSIT_CIDR" <<<"$_nexus_routes" || fail "Nexus spoke has no route back to transit $TRANSIT_CIDR"

  if printf '%s\n%s\n' "$_transit_routes" "$_nexus_routes" | grep -qxF "$AKS_CIDR"; then
    fail "AKS range $AKS_CIDR leaked into the hub"
  fi
  log "PASS routing: Nexus reachable via the hub; $AKS_CIDR never advertised"
}

do_nva() {
  load_outputs
  local _lb_id _avail

  _lb_id=$(az network lb show -g "$RESOURCE_GROUP" -n "ilb-${ENV_NAME}-nva" --query id -o tsv)
  # data[-2] is the last complete minute; the current minute is partial.
  _avail=$(az monitor metrics list --resource "$_lb_id" --metric DipAvailability --interval PT1M \
    --aggregation Average --offset 10m --query 'value[0].timeseries[0].data[-2].average' -o tsv)
  log "ILB backend health (DipAvailability, last full minute): ${_avail:-n/a}%"
  [[ "${_avail%.*}" == "100" ]] || fail "not all NVA instances are healthy"
  log "PASS nva: all NVA backends healthy"
}

# Prints the MASQUERADE destinations configured on one NVA instance (0.0.0.0/0 for a rule without -d).
nva_snat_destinations() {
  az vmss run-command invoke -g "$RESOURCE_GROUP" -n "$NVA_VMSS" --instance-id "$1" \
    --command-id RunShellScript --scripts "iptables -t nat -S POSTROUTING | grep MASQUERADE" \
    --query 'value[0].message' -o tsv |
    awk '/MASQUERADE/ { d = "0.0.0.0/0"; for (i = 1; i < NF; i++) if ($i == "-d") d = $(i + 1); print d }'
}

do_nva_reimage() {
  load_outputs
  local _id _dst _have

  for _id in $(az vmss list-instances -g "$RESOURCE_GROUP" -n "$NVA_VMSS" --query '[].instanceId' -o tsv); do
    log "Reimaging $NVA_VMSS instance $_id (the other instances keep serving behind the ILB)"
    az vmss reimage -g "$RESOURCE_GROUP" -n "$NVA_VMSS" --instance-ids "$_id" -o none
    _have=""
    for _ in $(seq 1 30); do
      _have=$(nva_snat_destinations "$_id" 2>/dev/null || true)
      [[ -n "$_have" ]] && break
      sleep 10
    done
    # Private clusters SNAT everything (one rule without -d); public clusters only private_destinations.
    for _dst in $([[ "$PRIVATE_CLUSTER" == "true" ]] && echo 0.0.0.0/0 || echo "$PRIVATE_DESTINATIONS"); do
      grep -qxF "$_dst" <<<"$_have" || fail "instance $_id has no SNAT rule for $_dst"
    done
    log "  instance $_id SNATs: $(tr '\n' ' ' <<<"$_have")"
  done
  log "PASS nva-reimage: every instance SNATs $([[ "$PRIVATE_CLUSTER" == "true" ]] && echo "all AKS egress" || echo "all private destinations")"
}

do_onprem() {
  load_outputs
  local _cidr _url _gw _transit_routes _learned _nva_ips _out _client _phase

  [[ "$ONPREM_JSON" != "null" ]] || fail "no simulated on-prem; apply with -var create_onprem_sim=true"
  _cidr=$(jq -r .cidr <<<"$ONPREM_JSON")
  _url=$(jq -r .echo_url <<<"$ONPREM_JSON")
  _gw=$(jq -r .gateway_name <<<"$ONPREM_JSON")

  _transit_routes=$(hub_routes "conn-${ENV_NAME}-transit")
  log "Hub routes on conn-${ENV_NAME}-transit: $(tr '\n' ' ' <<<"$_transit_routes")"
  grep -qxF "$_cidr" <<<"$_transit_routes" || fail "transit VNet has no hub route to on-prem $_cidr"

  _learned=$(az network vnet-gateway list-learned-routes -g "$RESOURCE_GROUP" -n "$_gw" \
    --query "value[?origin=='EBgp'].network" -o tsv | sort -u)
  log "On-prem gateway learned over BGP: $(tr '\n' ' ' <<<"$_learned")"
  grep -qxF "$TRANSIT_CIDR" <<<"$_learned" || fail "on-prem did not learn transit $TRANSIT_CIDR"
  if grep -qxF "$AKS_CIDR" <<<"$_learned"; then
    fail "AKS range $AKS_CIDR leaked to on-prem"
  fi

  ensure_tunnel
  log "Pod -> $_url (simulated on-prem server; NSG admits only the transit /28s)"
  kubectl -n "$NAMESPACE" delete pod onprem-test --ignore-not-found --wait=true >/dev/null
  # Deployment safeguards on AKS Automatic reject pods without resource requests.
  kubectl -n "$NAMESPACE" apply -f - <<EOF 2>&1 | grep -v '^Warning:' || true
apiVersion: v1
kind: Pod
metadata:
  name: onprem-test
spec:
  restartPolicy: Never
  containers:
    - name: onprem-test
      image: gcr.io/go-containerregistry/crane:debug
      command: ["/busybox/wget", "-q", "-T", "10", "-O-", "$_url"]
      resources:
        requests: {cpu: 50m, memory: 32Mi}
        limits: {cpu: 200m, memory: 64Mi}
EOF
  kubectl -n "$NAMESPACE" get pod onprem-test >/dev/null 2>&1 || fail "onprem-test pod was not created"
  _phase=Pending
  for _ in $(seq 1 60); do
    _phase=$(kubectl -n "$NAMESPACE" get pod onprem-test -o jsonpath='{.status.phase}' 2>/dev/null || echo Unknown)
    [[ "$_phase" == "Succeeded" || "$_phase" == "Failed" ]] && break
    sleep 5
  done
  _out=$(kubectl -n "$NAMESPACE" logs onprem-test 2>&1 || true)
  log "  on-prem server replied: ${_out}"
  [[ "$_phase" == "Succeeded" ]] || fail "pod could not reach on-prem (phase $_phase)"

  _client=$(sed -n 's/^client=\([0-9.]*\).*/\1/p' <<<"$_out")
  _nva_ips=$(az vmss nic list -g "$RESOURCE_GROUP" --vmss-name "$NVA_VMSS" \
    --query '[].ipConfigurations[0].privateIPAddress' -o tsv)
  # With the Azure Firewall test enabled for this env, the SNAT source is a firewall instance IP.
  _azfw_subnet=$(terraform -chdir="$TF_DIR" output -json azfw_test 2>/dev/null |
    jq -r --arg e "$ENV_NAME" 'select(. != null and .env == $e) | .subnet')
  if [[ -n "$_azfw_subnet" ]]; then
    python3 -c 'import ipaddress,sys; sys.exit(ipaddress.ip_address(sys.argv[1]) not in ipaddress.ip_network(sys.argv[2]))' \
      "$_client" "$_azfw_subnet" || fail "on-prem saw $_client, not an Azure Firewall IP ($_azfw_subnet)"
  else
    grep -qxF "$_client" <<<"$_nva_ips" || fail "on-prem saw $_client, not an NVA transit IP ($(tr '\n' ' ' <<<"$_nva_ips"))"
  fi
  log "PASS onprem: on-prem sees ${_azfw_subnet:+Azure Firewall IP}${_azfw_subnet:+ }${_azfw_subnet:-NVA transit IP} $_client; $AKS_CIDR never advertised to on-prem"
}

do_egress() {
  load_outputs
  local _sub _profile _routes _fw_pips _out _ip _phase

  [[ "$PRIVATE_CLUSTER" == "true" ]] || fail "public cluster; apply with -var private_clusters=true"
  _sub=$(az account show --query id -o tsv)
  _profile=$(az rest --method get \
    --url "https://management.azure.com/subscriptions/${_sub}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.ContainerService/managedClusters/${CLUSTER_NAME}?api-version=${AKS_API_VERSION}" \
    --query '{private: properties.apiServerAccessProfile.enablePrivateCluster, outbound: properties.networkProfile.outboundType, fqdn: properties.fqdn}' -o json)
  log "Cluster profile: $(jq -c . <<<"$_profile")"
  jq -e '.private == true' <<<"$_profile" >/dev/null || fail "API server is not private"
  jq -e '.outbound == "userDefinedRouting"' <<<"$_profile" >/dev/null || fail "outboundType is not userDefinedRouting"
  jq -e '.fqdn == null' <<<"$_profile" >/dev/null || fail "cluster still publishes a public FQDN"

  _routes=$(hub_routes "conn-${ENV_NAME}-transit")
  grep -qxF "0.0.0.0/0" <<<"$_routes" || fail "transit VNet did not learn the hub's 0.0.0.0/0"
  log "Transit VNet learned 0.0.0.0/0 from the hub (forced tunnelling)"

  _fw_pips=$(terraform -chdir="$TF_DIR" output -json hub_firewall_public_ips | jq -r '.[]?')
  [[ -n "$_fw_pips" ]] || fail "no hub firewall public IP in terraform output"

  ensure_tunnel
  kubectl -n "$NAMESPACE" delete pod egress-test --ignore-not-found --wait=true >/dev/null
  kubectl -n "$NAMESPACE" apply -f - <<EOF 2>&1 | grep -v '^Warning:' || true
apiVersion: v1
kind: Pod
metadata:
  name: egress-test
spec:
  restartPolicy: Never
  containers:
    - name: egress-test
      image: gcr.io/go-containerregistry/crane:debug
      command: ["/busybox/wget", "-q", "-T", "10", "-O-", "http://api.ipify.org"]
      resources:
        requests: {cpu: 50m, memory: 32Mi}
        limits: {cpu: 200m, memory: 64Mi}
EOF
  _phase=Pending
  for _ in $(seq 1 60); do
    _phase=$(kubectl -n "$NAMESPACE" get pod egress-test -o jsonpath='{.status.phase}' 2>/dev/null || echo Unknown)
    [[ "$_phase" == "Succeeded" || "$_phase" == "Failed" ]] && break
    sleep 5
  done
  _out=$(kubectl -n "$NAMESPACE" logs egress-test 2>&1 || true)
  [[ "$_phase" == "Succeeded" ]] || fail "pod has no internet egress (phase $_phase): $_out"
  _ip=$(grep -oE '^[0-9.]+$' <<<"$_out" | head -1)
  log "  pod internet egress IP: ${_ip:-?}; hub firewall public IPs: $(tr '\n' ' ' <<<"$_fw_pips")"
  grep -qxF "$_ip" <<<"$_fw_pips" || fail "pod egress $_ip did not leave through the hub firewall"
  log "PASS egress: private API server, userDefinedRouting, internet egress via the hub firewall $_ip"
}

do_ca_trust() {
  load_outputs
  local _set _want _sub

  _sub=$(az account show --query id -o tsv)
  _want=$(base64 <"$CA_FILE" | tr -d '\n')
  _set=$(az rest --method get \
    --url "https://management.azure.com/subscriptions/${_sub}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.ContainerService/managedClusters/${CLUSTER_NAME}?api-version=${AKS_API_VERSION}" \
    --query 'properties.securityProfile.customCATrustCertificates' -o json)
  jq -e --arg w "$_want" 'index($w) != null' <<<"$_set" >/dev/null ||
    fail "private CA is not in securityProfile.customCATrustCertificates"
  log "PASS ca-trust: private CA present in securityProfile.customCATrustCertificates"
}

do_pod_pull() {
  load_outputs
  ensure_tunnel
  log "Running Job nexus-pull-test (crane, TLS verified with nexus-ca)"
  kubectl -n "$NAMESPACE" delete job nexus-pull-test --ignore-not-found --wait=true >/dev/null
  kubectl apply -f "${TF_DIR}/k8s/nexus-pull-test.yaml" 2>&1 | grep -v '^Warning:' || true
  if ! kubectl -n "$NAMESPACE" wait --for=condition=complete job/nexus-pull-test --timeout="${POD_TIMEOUT}s"; then
    kubectl -n "$NAMESPACE" logs job/nexus-pull-test --tail=30 || true
    fail "nexus-pull-test did not complete"
  fi
  kubectl -n "$NAMESPACE" logs job/nexus-pull-test | grep -E '^(Node IP|Pulled|SUCCESS)' |
    while read -r l; do log "  $l"; done
  log "PASS pod-pull"
}

# Succeeded, Running, X509, or the current waiting reason of the CURRENT pod.
# Reads pod status (not events) so results from earlier pods can't leak in.
kubelet_pod_state() {
  local _json
  _json=$(kubectl -n "$NAMESPACE" get pod kubelet-pull-test -o json 2>/dev/null) || {
    echo Missing
    return
  }
  jq -r '
    (.status.containerStatuses[0].state.waiting // {}) as $w
    | if ($w.message // "" | test("x509")) then "X509"
      elif .status.phase == "Succeeded" or .status.phase == "Running" then .status.phase
      else ($w.reason // .status.phase) end' <<<"$_json"
}

# Sets KUBELET_STATE.
run_kubelet_pod() {
  local _deadline _node

  kubectl -n "$NAMESPACE" delete pod kubelet-pull-test --ignore-not-found --wait=true >/dev/null
  kubectl apply -f "${TF_DIR}/k8s/kubelet-pull-test.yaml" 2>&1 | grep -v '^Warning:' || true
  _deadline=$((SECONDS + POD_TIMEOUT))
  KUBELET_STATE=Pending
  while ((SECONDS < _deadline)); do
    KUBELET_STATE=$(kubelet_pod_state)
    case "$KUBELET_STATE" in
      Succeeded | Running | X509) break ;;
    esac
    sleep 10
  done
  _node=$(kubectl -n "$NAMESPACE" get pod kubelet-pull-test -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)
  log "  pod state: $KUBELET_STATE (node: ${_node:-unscheduled})"
}

do_recycle_nodes() {
  load_outputs
  ensure_tunnel
  log "Deleting NAP NodeClaims (graceful drain; NAP provisions replacements with the current node config)"
  kubectl get nodeclaims --no-headers \
    -o custom-columns=NAME:.metadata.name,POOL:.metadata.labels.karpenter\\.sh/nodepool,CREATED:.metadata.creationTimestamp |
    while read -r l; do log "  $l"; done
  kubectl delete nodeclaims --all --wait=true
  log "NodeClaims recycled"
}

do_kubelet_pull() {
  load_outputs
  ensure_tunnel
  log "Kubelet pull: $(awk '/image:/ {print $2; exit}' "${TF_DIR}/k8s/kubelet-pull-test.yaml")"
  run_kubelet_pod
  if [[ "$KUBELET_STATE" == "X509" && "$RECYCLE_NODES" == "true" ]]; then
    log "  x509 on a node that predates CA trust; recycling NAP nodes and retrying"
    do_recycle_nodes
    run_kubelet_pod
  fi

  case "$KUBELET_STATE" in
    Succeeded | Running)
      kubectl -n "$NAMESPACE" get events --field-selector involvedObject.name=kubelet-pull-test,reason=Pulled \
        -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' | tail -1 | while read -r l; do log "  $l"; done
      log "PASS kubelet-pull"
      ;;
    X509) fail "kubelet rejects the Nexus certificate (x509). Check ca-trust; rerun with RECYCLE_NODES=true." ;;
    *) fail "kubelet-pull-test ended in state '$KUBELET_STATE'" ;;
  esac
}

do_cleanup() {
  load_outputs
  ensure_tunnel
  kubectl -n "$NAMESPACE" delete job nexus-pull-test --ignore-not-found >/dev/null
  kubectl -n "$NAMESPACE" delete pod kubelet-pull-test --ignore-not-found >/dev/null
  kubectl -n "$NAMESPACE" delete pod onprem-test --ignore-not-found >/dev/null
  kubectl -n "$NAMESPACE" delete pod egress-test --ignore-not-found >/dev/null
  log "Test workloads deleted"
  close_tunnel
}

do_all() {
  check_dependencies
  do_setup
  do_routing
  do_nva
  do_ca_trust
  do_pod_pull
  do_kubelet_pull
  if [[ "$PRIVATE_CLUSTER" == "true" ]]; then
    do_egress
  else
    log "SKIP egress: public cluster (private_clusters=false)"
  fi
  if [[ "$ONPREM_JSON" != "null" ]]; then
    do_onprem
  else
    log "SKIP onprem: no simulated on-prem (create_onprem_sim=false)"
  fi
  log ""
  log "ALL TESTS PASSED for $ENV_NAME"
}

exec_case() {
  local _opt=$1

  case ${_opt} in
    all) do_all ;;
    check-deps) check_dependencies ;;
    setup) do_setup ;;
    routing) do_routing ;;
    nva) do_nva ;;
    ca-trust) do_ca_trust ;;
    pod-pull) do_pod_pull ;;
    kubelet-pull) do_kubelet_pull ;;
    egress) do_egress ;;
    onprem) do_onprem ;;
    recycle-nodes) do_recycle_nodes ;;
    nva-reimage) do_nva_reimage ;;
    cleanup) do_cleanup ;;
    *) usage ;;
  esac
  unset _opt
}

################################################################################
# Entry point
main() {
  local exec_flag=false

  while getopts "x:" opt; do
    case $opt in
      x)
        exec_flag=true
        EXEC_OPT="${OPTARG}"
        ;;
      *) usage ;;
    esac
  done
  shift $((OPTIND - 1))

  if [ $OPTIND = 1 ]; then
    print_header
    usage
  fi

  if [[ "${exec_flag}" == "true" ]]; then
    print_header
    exec_case "${EXEC_OPT}"
  fi
}

main "$@"
exit 0
