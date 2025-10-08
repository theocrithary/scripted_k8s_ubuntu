#!/bin/bash

# ==============================================================================
# Single-Node Kubernetes Cluster Installation Script
#
# This script automates the full setup of a single-node Kubernetes cluster
# on an Ubuntu 22.04 server using kubeadm.
#
# Requirement For docker - create a personal access token (PAT) on Docker Hub and provide
# it along with your Docker Hub username to avoid unauthenticated pull rate limits.
# https://app.docker.com/
#
# It performs the following steps:
# 1. Sets environment variables.
# 2. Prepares the host by disabling swap and configuring kernel modules.
# 3. Installs and configures the containerd runtime.
# 4. Installs kubeadm, kubelet, and kubectl from the official Kubernetes repository.
# 5. Install Helm CLI.
# 6. Initializes the single-node control plane.
# 7. Configures kubectl for the current user.
# 8. Untaints the master node so it can run pods.
# 9. Deploys a Pod Network Add-on (Calico).
# 10. Install Docker client tools.
# 11. Restart calico-node to ensure networking initializes cleanly.
# 12. Install MetalLB Load Balancer.
#
# IMPORTANT: This script requires root privileges.

# ALSO IMPORTANT: add execute permissions with: sudo chmod +x install-k8s.sh

#  How to use the modified script with the docker login
# export DOCKER_USER=your_dockerhub_username
# export DOCKER_TOKEN=your_personal_access_token
# sudo ./install-k8s.sh

# Or pass flags
# sudo ./install-k8s.sh -U your_dockerhub_username -T your_personal_access_token
# sudo API_HOST=myk8s.dapdemo.lab ./install-k8s.sh -U mydockeruser -T mytoken


# ==============================================================================

set -e

# ================================
# 1. User configurable variables
# ================================

# The version of Kubernetes to install.
KUBE_VERSION="1.30.14-1.1"
API_HOST="k8s.lab.local"

# The IP address for MetalLB to use for LoadBalancer service.
# This IP MUST be configured to a free IP on your local network that
# is NOT managed by your router's DHCP server.
# for a single node k8s, you can use the host's IP with /32 mask
METALLB_IP="192.168.0.25/32"

# ================================
# Parse Docker Hub credentials (required to avoid unauthenticated pull rate limits)
# You can provide DOCKER_USER and DOCKER_TOKEN as environment variables or
# pass them as flags to the script: -U <user> -T <token>
while getopts ":U:T:G:g:Q:q:A:F" opt; do
  case $opt in
    U) PARSE_DOCKER_USER="$OPTARG";;
    T) PARSE_DOCKER_TOKEN="$OPTARG";;
    G) PARSE_GHCR_USER="$OPTARG";;
    g) PARSE_GHCR_TOKEN="$OPTARG";;
    Q) PARSE_QUAY_USER="$OPTARG";;
    q) PARSE_QUAY_TOKEN="$OPTARG";;
    A) PARSE_API_HOST="$OPTARG";;
    F) PARSE_OPEN_FIREWALL=1;;
    \?) echo "Invalid option: -$OPTARG"; exit 1;;
  esac
done

# Prefer environment variables if set, otherwise use parsed flags
DOCKER_USER="${DOCKER_USER:-$PARSE_DOCKER_USER}"
DOCKER_TOKEN="${DOCKER_TOKEN:-$PARSE_DOCKER_TOKEN}"
GHCR_USER="${GHCR_USER:-$PARSE_GHCR_USER}"
GHCR_TOKEN="${GHCR_TOKEN:-$PARSE_GHCR_TOKEN}"
QUAY_USER="${QUAY_USER:-$PARSE_QUAY_USER}"
QUAY_TOKEN="${QUAY_TOKEN:-$PARSE_QUAY_TOKEN}"
API_HOST="${API_HOST:-$PARSE_API_HOST}"
OPEN_FIREWALL="${OPEN_FIREWALL:-${PARSE_OPEN_FIREWALL:-0}}"

if [ -z "$DOCKER_USER" ] || [ -z "$DOCKER_TOKEN" ]; then
  echo "ERROR: Docker Hub credentials are required to avoid rate limits."
  echo "Set DOCKER_USER and DOCKER_TOKEN environment variables or pass -U <user> -T <token> to the script."
  exit 1
fi

# Ensure root docker config contains auth so containerd can use authenticated pulls
mkdir -p /root/.docker
if command -v base64 >/dev/null 2>&1; then
  # base64 options differ across platforms; prefer -w0 when available
  if base64 --help 2>&1 | grep -q -- -w; then
    AUTH_B64=$(printf "%s:%s" "$DOCKER_USER" "$DOCKER_TOKEN" | base64 -w0)
  else
    AUTH_B64=$(printf "%s:%s" "$DOCKER_USER" "$DOCKER_TOKEN" | base64)
  fi
else
  AUTH_B64=""
fi
cat > /root/.docker/config.json <<EOF
{
  "auths": {
    "https://index.docker.io/v1/": {
      "auth": "${AUTH_B64}"
    },
    "https://registry-1.docker.io/": {
      "auth": "${AUTH_B64}"
    }
  }
}
EOF
chmod 600 /root/.docker/config.json
chown root:root /root/.docker/config.json

# ================================
# Helper functions for logging with timestamps and elapsed time
# ================================
# Helper: print elapsed time since script start in human-friendly form
elapsed_since() {
  # elapsed since given timestamp (seconds)
  local since_ts=$1
  local now=$(date +%s)
  local diff=$((now - since_ts))
  local hours=$((diff / 3600))
  local mins=$(((diff % 3600) / 60))
  local secs=$((diff % 60))
  printf "%02dh:%02dm:%02ds" "$hours" "$mins" "$secs"
}

# Helper: log section start with timestamp and elapsed time since previous section
log_section_start() {
  local section_title="$1"
  local now_human=$(timestamp)
  local elapsed_since_prev=$(elapsed_since "$SECTION_START_TS")
  echo ""
  echo " # =============================================== "
  echo "\n--> [${now_human}] Starting: ${section_title} (since previous: ${elapsed_since_prev})\n"
  echo " # =============================================== "
   # update SECTION_START_TS to now for the next section
  SECTION_START_TS=$(date +%s)
}


# Restart containerd so it can pick up any auth config (no-op if not running yet)
if systemctl list-units --type=service --state=active | grep -q containerd; then
  systemctl restart containerd || true
fi

# ================================
# Define Cluster Variables
# ================================
log_section_start "1. Define Cluster Variables"
# Record script start time for elapsed calculations
SCRIPT_START_TS=$(date +%s)
SCRIPT_START_TIME_HUMAN=$(date --iso-8601=seconds)
echo "Script started at: ${SCRIPT_START_TIME_HUMAN}"

# Track last section start time so we can report elapsed time between sections
SECTION_START_TS=${SCRIPT_START_TS}

# Helper: print a timestamp
timestamp() {
  date --iso-8601=seconds
}

# ================================
# 2. Pre-requisites and Host Prep
# ================================
log_section_start "2. Pre-requisites and Host Prep"
echo "--> Preparing the host system..."

# Ensure we're running as root or with sudo
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script with sudo."
  exit
fi

# Disable swap to meet Kubernetes requirements
echo "--> Disabling swap..."
swapoff -a
# Permanently disable swap in fstab by commenting out the swap line.
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# Load kernel modules and configure sysctl for Kubernetes networking
echo "--> Configuring kernel modules for Kubernetes..."
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

# Configure sysctl settings for Kubernetes networking
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

# Apply sysctl parameters without a reboot
sysctl --system

# Install and start chrony for time synchronization
echo "--> Installing and configuring chrony for time synchronization..."
apt-get update
apt-get install -y chrony
systemctl enable --now chrony
systemctl restart chrony

# Disable the firewall (UFW) to prevent networking issues within the cluster
echo "--> Disabling the firewall (ufw)..."
ufw disable

# ============================================
# 3. Install Container Runtime (containerd)
# ============================================
log_section_start "3. Install Container Runtime (containerd)"
echo "--> Installing containerd runtime..."
apt-get update
apt-get install -y containerd

# Configure containerd and restart the service
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml
# Set the cgroup driver for containerd to systemd, which is what kubelet uses.
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

# ============================================
# 4. Install Kubeadm, Kubelet, and Kubectl
# ============================================
log_section_start "4. Install Kubeadm, Kubelet, and Kubectl"
echo "--> Installing Kubernetes tools (kubeadm, kubelet, kubectl)..."

# Add the official Kubernetes apt repository key
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# Add the repository to your system's apt sources list
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list

# Update apt package index
apt-get update

# Install the specific version and hold them to prevent future upgrades
apt-get install -y kubelet="$KUBE_VERSION" kubeadm="$KUBE_VERSION" kubectl="$KUBE_VERSION"
apt-mark hold kubelet kubeadm kubectl

# Enable the kubelet service
systemctl enable --now kubelet

# ============================================
# 5. Install Helm CLI
# ============================================
log_section_start "5. Install Helm CLI"
echo "--> Install Helm CLI"

# Download and install the Helm CLI
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh
rm get_helm.sh

# ============================================
# 6. Initialize the Control Plane
# ============================================
log_section_start "6. Initialize the Control Plane"
echo "--> Initializing the Kubernetes control plane..."

cat <<EOF | kubeadm init --upload-certs 
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
controlPlaneEndpoint: "$API_HOST:6443"
kubernetesVersion: v1.30.4
networking:
    podSubnet: 161.200.0.0/16
    serviceSubnet: 161.210.0.0/16
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
serverTLSBootstrap: true
maxPods: 150
EOF

# ============================================
# 7. Configure Kubectl for the Current User
# ============================================
log_section_start "7. Configure Kubectl for the Current User"
echo "--> Configuring kubectl for the current user..."
mkdir -p "$HOME"/.kube
cp -i /etc/kubernetes/admin.conf "$HOME"/.kube/config
chown "$(id -u)":"$(id -g)" "$HOME"/.kube/config

# ============================================
# 8. Untaint the Control Plane Node (for single node setup)
# ============================================
log_section_start "8. Untaint the Control Plane Node"
echo "--> Untainting the master node to run pods..."
# Get the node name and untaint it
NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
kubectl taint nodes "$NODE_NAME" node-role.kubernetes.io/control-plane:NoSchedule-

# ============================================
# 9. Install a Pod Network Add-on (Calico)
# ============================================
log_section_start "9. Install a Pod Network Add-on (Calico)"
echo "--> Deploying Calico Pod Network Add-on..."
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.5/manifests/calico.yaml

# ============================================
# 10. Install Docker client tools - V2
# ============================================
log_section_start "10. Install Docker client tools"
echo "--> Installing Docker client tools..."

# Install required dependencies
apt-get update
apt-get install -y ca-certificates curl gnupg lsb-release

# Add Docker’s official GPG key
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  gpg --dearmor -o /etc/apt/keyrings/docker.gpg

# Add Docker repository to APT sources
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

# Update package index
apt-get update

# Install containerd.io with config conflict suppression
DEBIAN_FRONTEND=noninteractive apt-get install -y containerd.io \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold"

# Generate default containerd config and set cgroup driver to systemd
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml > /dev/null
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# Restart containerd to apply changes
systemctl restart containerd
systemctl enable containerd

# Install Docker CE and CLI with same suppression
DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli \
  -o Dpkg::Options::="--force-confdef" \
  -o Dpkg::Options::="--force-confold"

# Enable and start Docker service
systemctl enable --now docker

# Add current user to Docker group
usermod -aG docker $USER

# Perform Docker CLI login so Docker client has authenticated access (helps with pulls)
if command -v docker >/dev/null 2>&1; then
  echo "Logging in to Docker Hub as ${DOCKER_USER}..."
  if echo "$DOCKER_TOKEN" | docker login --username "$DOCKER_USER" --password-stdin >/dev/null 2>&1; then
    echo "Docker Hub login successful."
  else
    echo "ERROR: Docker Hub login failed. Check DOCKER_USER/DOCKER_TOKEN and try again." >&2
    echo "You can export DOCKER_USER and DOCKER_TOKEN or pass -U and -T flags." >&2
    exit 1
  fi

  # Optional: login to GHCR or Quay if tokens were provided (useful when images are on ghcr.io or quay.io)
  # Use env GHCR_USER and GHCR_TOKEN or QUAY_USER and QUAY_TOKEN
  if [ -n "${GHCR_USER:-}" ] && [ -n "${GHCR_TOKEN:-}" ]; then
    echo "Logging in to GHCR as ${GHCR_USER}..."
    if echo "$GHCR_TOKEN" | docker login ghcr.io --username "$GHCR_USER" --password-stdin >/dev/null 2>&1; then
      echo "GHCR login successful."
    else
      echo "WARNING: GHCR login failed. If MetalLB images are on GHCR, pulls may fail." >&2
    fi
  fi

  if [ -n "${QUAY_USER:-}" ] && [ -n "${QUAY_TOKEN:-}" ]; then
    echo "Logging in to Quay as ${QUAY_USER}..."
    if echo "$QUAY_TOKEN" | docker login quay.io --username "$QUAY_USER" --password-stdin >/dev/null 2>&1; then
      echo "Quay login successful."
    else
      echo "WARNING: Quay login failed. If images are on Quay, pulls may fail." >&2
    fi
  fi
fi

# Pre-pull common images with explicit credentials using ctr to avoid unauthenticated rate limits
if command -v ctr >/dev/null 2>&1; then
  IMAGES=(
    "docker.io/calico/cni:v3.28.5"
    "docker.io/calico/node:v3.28.5"
    "docker.io/calico/kube-controllers:v3.28.5"
    "docker.io/coredns/coredns:1.10.1"
    "docker.io/metallb/controller:v0.13.12"
  )
  registries=("docker.io" "ghcr.io" "quay.io" "registry.k8s.io")
  for img in "${IMAGES[@]}"; do
    echo "Pre-pulling ${img} with credentials/aliases..."
    # Extract the image path after possible registry (e.g. metallb/controller:v0.13.12)
    if [[ "$img" == *"/"* ]]; then
      image_path="${img#*/}"
    else
      image_path="$img"
    fi

    success=0
    for reg in "${registries[@]}"; do
      candidate="${reg}/${image_path}"
      echo "Trying candidate: ${candidate}"

      # First try ctr with explicit credentials for docker.io candidates
      if [[ "$reg" == "docker.io" ]]; then
        if ctr -n k8s.io images pull --user "${DOCKER_USER}:${DOCKER_TOKEN}" "$candidate"; then
          echo "ctr pull succeeded for ${candidate}"
          success=1
          break
        else
          echo "ctr pull failed for ${candidate}"
        fi
      else
        # Try unauthenticated ctr pull for other registries
        if ctr -n k8s.io images pull "$candidate"; then
          echo "ctr pull succeeded for ${candidate}"
          success=1
          break
        else
          echo "ctr pull failed for ${candidate}"
        fi
      fi

      # If ctr failed, try docker pull + import (docker login was earlier)
      if command -v docker >/dev/null 2>&1; then
        echo "Attempting docker pull for ${candidate}"
        if docker pull "$candidate"; then
          echo "docker pull succeeded for ${candidate}; importing into containerd..."
          if docker save "$candidate" | ctr -n k8s.io images import -; then
            echo "Imported ${candidate} into containerd"
            success=1
            break
          else
            echo "Import failed for ${candidate}"
          fi
        else
          echo "docker pull failed for ${candidate}"
        fi
      else
        echo "docker CLI not available for fallback"
      fi

      # small pause between candidate attempts
      sleep 1
    done

    if [ "$success" -ne 1 ]; then
      echo "All candidate pulls failed for ${img}"
    fi
  done
fi

# Validate which images were successfully pulled and print a summary
validate_pulled_images() {
  echo "\n== Image pull validation summary =="
  if command -v ctr >/dev/null 2>&1; then
    for img in "${IMAGES[@]}"; do
      if ctr -n k8s.io images ls | awk '{print $1}' | grep -q "${img%%:*}"; then
        echo "OK: ${img} is present in containerd"
      else
        echo "MISSING: ${img} was NOT found in containerd"
      fi
    done
  elif command -v crictl >/dev/null 2>&1; then
    for img in "${IMAGES[@]}"; do
      if crictl images | awk '{print $1":"$2}' | grep -q "${img}"; then
        echo "OK: ${img} is present (crictl)"
      else
        echo "MISSING: ${img} was NOT found (crictl)"
      fi
    done
  else
    echo "No ctr or crictl found to validate images. Skipping validation."
  fi
  echo "== End summary ==\n"
}

validate_pulled_images

# ============================================
# 11. Restart calico-node to ensure networking initializes cleanly
# ============================================

log_section_start "11. Restart calico-node to ensure networking initializes cleanly"
echo "--> Restarting calico-node daemonset to ensure CNI is ready..."
kubectl rollout restart daemonset calico-node -n kube-system

# Wait for all Calico pods to be Running
echo "--> Waiting for Calico pods to become Ready..."

START_TIME=$(date +%s)

until kubectl get pods -n kube-system --no-headers | grep calico | awk '{if ($3 != "Running") exit 1}'; do
  CURRENT_TIME=$(date +%s)
  ELAPSED=$((CURRENT_TIME - START_TIME))
  MINUTES=$((ELAPSED / 60))
  SECONDS=$((ELAPSED % 60))
  echo "Still waiting for Calico... elapsed time: ${MINUTES}m ${SECONDS}s"
  sleep 15
done

echo "--> All Calico pods are Ready after ${MINUTES}m ${SECONDS}s."

# ============================================
# 12. Install MetalLB
# ============================================
log_section_start "12. Install MetalLB"
echo "--> Installing MetalLB Load Balancer..."

# Add the MetalLB Helm repository
helm repo add metallb https://metallb.github.io/metallb

# Update the Helm repository cache
helm repo update

# Install MetalLB from the Helm chart
helm install metallb metallb/metallb --namespace metallb-system --create-namespace

# Create a manifest to configure MetalLB with an IP address pool

cat <<EOF > metallb.yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata: 
  name: ip-pool 
  namespace: metallb-system
spec: 
  addresses: 
  - $METALLB_IP
EOF

log_section_start "13. Setup MetalLB pool"
echo "--> Waiting for all system pods in kube-system namespace to be Ready..."

START_TIME=$(date +%s)

# Loop until all pods in kube-system are Running or Completed
until kubectl get pods -n kube-system --no-headers | awk '{if ($3 != "Running" && $3 != "Completed") exit 1}' ; do
  CURRENT_TIME=$(date +%s)
  ELAPSED=$((CURRENT_TIME - START_TIME))
  MINUTES=$((ELAPSED / 60))
  SECONDS=$((ELAPSED % 60))
  echo "Still waiting... elapsed time: ${MINUTES}m ${SECONDS}s"
  sleep 15
done

echo "--> All system pods are Ready after ${MINUTES}m ${SECONDS}s. Proceeding with MetalLB configuration..."

# Apply the MetalLB configuration
kubectl apply -f metallb.yaml

# ============================================
# Installation Complete
# ============================================
log_section_start "Installation Complete"
kubectl get pods -n kube-system

echo " # =============================================== "
echo ""

# Print total script runtime
if [ -n "${SCRIPT_START_TS:-}" ]; then
  now_ts=$(date +%s)
  total_sec=$((now_ts - SCRIPT_START_TS))
  hrs=$((total_sec / 3600))
  mins=$(((total_sec % 3600) / 60))
  secs=$((total_sec % 60))
  printf "\nTotal script runtime: %02dh:%02dm:%02ds\n" "$hrs" "$mins" "$secs"
fi
echo ""

# ============================================
# Post-installation: Export kubeconfig and print connection info
# ============================================

# Export kubeconfig to current directory and print to screen
KUBECONF_SRC="/etc/kubernetes/admin.conf"
if [ -f "$KUBECONF_SRC" ]; then
  EXEC_DIR="$(pwd)"
  KUBECONF_OUT="$EXEC_DIR/kubeconfig"
  KUBECONF_CFG="$EXEC_DIR/kubeconfig.config"
  echo "Exporting kubeconfig to: $KUBECONF_OUT and $KUBECONF_CFG"
  cp "$KUBECONF_SRC" "$KUBECONF_OUT"
  cp "$KUBECONF_SRC" "$KUBECONF_CFG"
  chmod 666 "$KUBECONF_OUT" || true
  chmod 666 "$KUBECONF_CFG" || true
  echo "\n---- kubeconfig (begin) ----"
  echo ""
  sed -n '1,200p' "$KUBECONF_SRC"
  echo ""
  echo "---- kubeconfig (end) ----\n"
  echo ""
  # If the user provided an external API host or DNS, update the server: fields
  if [ -n "${API_HOST:-}" ]; then
    # ensure host includes port
    if echo "$API_HOST" | grep -q ':'; then
      HOSTPORT="$API_HOST"
    else
      HOSTPORT="${API_HOST}:6443"
    fi
    # Update the server field in the exported kubeconfigs to use the provided host
    sed -i -E "s@(server:[[:space:]]*https?://)[^\" ]+@\1${HOSTPORT}@g" "$KUBECONF_OUT" || true
    sed -i -E "s@(server:[[:space:]]*https?://)[^\" ]+@\1${HOSTPORT}@g" "$KUBECONF_CFG" || true
    echo "Updated exported kubeconfigs to use https://${HOSTPORT} as API server"
  fi
else
  echo "Warning: $KUBECONF_SRC not found; cannot export kubeconfig."
fi

# ============================================
# Post-installation: Print API endpoint and export certs
# ============================================

# Print external API endpoint information (from kubeconfig or fallback)
API_ENDPOINT=""
if [ -f "$KUBECONF_SRC" ]; then
  # try to parse server URL from admin.conf. This extracts host:port from the server field.
  API_ENDPOINT=$(sed -n '1,200p' "$KUBECONF_SRC" | grep 'server:' | head -n1 | sed -E 's/.*server:[[:space:]]*https?:\/\/(.*)/\1/' | tr -d '\"') || API_ENDPOINT=""
fi

if [ -z "$API_ENDPOINT" ]; then
  # attempt to find primary non-loopback IPv4 for this host
  HOST_IP=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+\.\d+\.\d+\.\d+' | head -n1 || true)
  if [ -n "$HOST_IP" ]; then
    API_ENDPOINT="${HOST_IP}:6443"
  else
    API_ENDPOINT="<node-ip>:6443"
    API_ENDPOINT="<node-ip>:6443"
  fi
fi

echo "\nCluster API endpoint (use this externally): ${API_ENDPOINT}"
if [ -f "$KUBECONF_OUT" ]; then
  echo " # =============================================== "
  echo ""
  echo "You can use the exported kubeconfig file to connect:"
  echo "  KUBECONFIG=$(pwd)/kubeconfig kubectl get nodes --server=https://${API_ENDPOINT}"
else
  echo "If you have an admin kubeconfig, you can use kubectl like this (replace <kubeconfig>):"
  echo "  KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes --server=https://${API_ENDPOINT}"
fi

# Export CA and client certificates from the admin kubeconfig (PEM + DER)
if [ -f "$KUBECONF_SRC" ]; then
  # ensure EXEC_DIR is set
  EXEC_DIR="${EXEC_DIR:-$(pwd)}"

  base64_decode() {
    if command -v base64 >/dev/null 2>&1; then
      if base64 --help 2>&1 | grep -q -- --decode; then
        base64 --decode
      else
        base64 -d
      fi
    elif command -v openssl >/dev/null 2>&1; then
      openssl base64 -d -A
    else
      return 1
    fi
  }

  ca_b64=$(grep 'certificate-authority-data:' "$KUBECONF_SRC" | head -n1 | awk '{print $2}' | tr -d '"' || true)
  if [ -n "$ca_b64" ]; then
    CA_PEM="$EXEC_DIR/ca.crt.pem"
    CA_DER="$EXEC_DIR/ca.crt.der"
    printf "%s" "$ca_b64" | base64_decode > "$CA_PEM" 2>/dev/null || true
    if [ -s "$CA_PEM" ]; then
      chmod 666 "$CA_PEM" || true
      if command -v openssl >/dev/null 2>&1; then
        openssl x509 -in "$CA_PEM" -outform DER -out "$CA_DER" 2>/dev/null || true
        [ -f "$CA_DER" ] && chmod 666 "$CA_DER" || true
        echo "Exported CA certificate: $CA_PEM (PEM) and $CA_DER (DER)"
      else
        echo "Exported CA certificate: $CA_PEM (PEM) - openssl not found, DER skipped"
      fi
    else
      echo "[WARN] Failed to decode certificate-authority-data from $KUBECONF_SRC"
    fi
  else
    echo "[INFO] No certificate-authority-data found in $KUBECONF_SRC"
  fi

  client_b64=$(grep 'client-certificate-data:' "$KUBECONF_SRC" | head -n1 | awk '{print $2}' | tr -d '"' || true)
  if [ -n "$client_b64" ]; then
    CLIENT_PEM="$EXEC_DIR/client.crt.pem"
    CLIENT_DER="$EXEC_DIR/client.crt.der"
    printf "%s" "$client_b64" | base64_decode > "$CLIENT_PEM" 2>/dev/null || true
    if [ -s "$CLIENT_PEM" ]; then
      chmod 666 "$CLIENT_PEM" || true
      if command -v openssl >/dev/null 2>&1; then
        openssl x509 -in "$CLIENT_PEM" -outform DER -out "$CLIENT_DER" 2>/dev/null || true
        [ -f "$CLIENT_DER" ] && chmod 666 "$CLIENT_DER" || true
        echo "Exported client certificate: $CLIENT_PEM (PEM) and $CLIENT_DER (DER)"
      else
        echo "Exported client certificate: $CLIENT_PEM (PEM) - openssl not found, DER skipped"
      fi
    else
      echo "[WARN] Failed to decode client-certificate-data from $KUBECONF_SRC"
    fi
  else
    echo "[INFO] No client-certificate-data found in $KUBECONF_SRC"
  fi
fi