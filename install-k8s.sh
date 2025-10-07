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
# 1. Sets environment variables for versioning.
# 2. Prepares the host by disabling swap and configuring kernel modules.
# 3. Installs and configures the containerd runtime.
# 4. Installs kubeadm, kubelet, and kubectl from the official Kubernetes repository.
# 5. Initializes the single-node control plane.
# 6. Configures kubectl for the current user.
# 7. Deploys a Pod Network Add-on (Calico).
# 8. Taints the master node so it can run pods.
#
# IMPORTANT: This script requires root privileges.

# ALSO IMPORTANT: update the shell permissions with: chmod 777 install-k8s.sh

#  How to use the modified script with the docker login
# export DOCKER_USER=your_dockerhub_username
# export DOCKER_TOKEN=your_personal_access_token
# sudo ./install-k8s.sh

# Or pass flags
# sudo ./install-k8s.sh -U your_dockerhub_username -T your_personal_access_token

# Sonders example:
# sudo ./install-k8s.sh -U rfsonders -T dckr_pat_l5HNijhmlP1p-82GGsOujnscYz4

# ==============================================================================

set -e

# ================================
# Parse Docker Hub credentials (required to avoid unauthenticated pull rate limits)
# You can provide DOCKER_USER and DOCKER_TOKEN as environment variables or
# pass them as flags to the script: -U <user> -T <token>
while getopts ":U:T:G:g:Q:q:" opt; do
  case $opt in
    U) PARSE_DOCKER_USER="$OPTARG";;
    T) PARSE_DOCKER_TOKEN="$OPTARG";;
    G) PARSE_GHCR_USER="$OPTARG";;
    g) PARSE_GHCR_TOKEN="$OPTARG";;
    Q) PARSE_QUAY_USER="$OPTARG";;
    q) PARSE_QUAY_TOKEN="$OPTARG";;
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
  echo " # =============================================== "
  echo "\n--> [${now_human}] Starting: ${section_title} (since previous: ${elapsed_since_prev})\n"
  echo " # =============================================== "
  echo ""
   # update SECTION_START_TS to now for the next section
  SECTION_START_TS=$(date +%s)
}


# Restart containerd so it can pick up any auth config (no-op if not running yet)
if systemctl list-units --type=service --state=active | grep -q containerd; then
  systemctl restart containerd || true
fi

# ================================
# 1. Define Cluster Variables
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


# The version of Kubernetes to install. As of today, v1.30 is the latest stable release.
# You can change this to v1.31.0-00 once that version is released.
KUBE_VERSION="1.30.14-1.1"

# The CIDR for the pod network. This is required for Calico.
#POD_NETWORK_CIDR="161.200.0.0/16"

# The IP address range for MetalLB to use for LoadBalancer services.
# This range MUST be configured to a free range on your local network that
# is NOT managed by your router's DHCP server.
METALLB_IP_RANGE="192.168.0.90-192.168.0.95"

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
log_section_start "5 Install Helm CLI"
echo "--> Install Helm CLI"

install_helm_with_retries() {
  local tries=3
  local wait_sec=5
  local attempt=1
  local workdir

  apt-get update
  apt-get install -y ca-certificates curl tar gzip

  # Determine OS and ARCH for helm release asset
  local os="linux"
  local raw_arch
  raw_arch=$(uname -m)
  local arch
  case "$raw_arch" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    armv7l|armhf) arch="arm" ;;
    ppc64le) arch="ppc64le" ;;
    s390x) arch="s390x" ;;
    *) arch="amd64" ;;
  esac

  while [ $attempt -le $tries ]; do
    echo "Attempt $attempt: fetch latest helm release tag..."
    # fetch latest tag name from GitHub releases
    tag=$(curl -fsSL "https://api.github.com/repos/helm/helm/releases/latest" | grep -m1 '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/') || tag=""
    if [ -z "$tag" ]; then
      echo "Failed to determine latest helm tag (network or API rate limit)."
      tag="v3.11.2"
      echo "Falling back to $tag"
    else
      echo "Latest helm tag: $tag"
    fi

    tarball_url="https://get.helm.sh/helm-${tag}-${os}-${arch}.tar.gz"
    echo "Downloading ${tarball_url}"

    workdir=$(mktemp -d -t helm-install-XXXX)
    tmpfile="$workdir/helm-${tag}.tar.gz"

    if curl -fsSLo "$tmpfile" "$tarball_url"; then
      echo "Downloaded helm tarball to $tmpfile"
      if tar -xzf "$tmpfile" -C "$workdir"; then
        # extracted path is ${os}-${arch}/helm
        binpath="$workdir/${os}-${arch}/helm"
        if [ -f "$binpath" ]; then
          echo "Installing helm binary to /usr/local/bin"
          install -m 0755 "$binpath" /usr/local/bin/helm && {
            rm -rf "$workdir"
            echo "Helm installed successfully."
            return 0
          } || {
            echo "Failed to move helm to /usr/local/bin (permission issue?)"
          }
        else
          echo "Helm binary not found in archive"
        fi
      else
        echo "Failed to extract helm tarball"
      fi
    else
      echo "Download failed (network or 404): $tarball_url"
    fi

    # log for diagnosis
    echo "Installer attempt $attempt failed; see /tmp/helm_install_${attempt}.log if present"
    attempt=$((attempt + 1))
    echo "Waiting ${wait_sec}s before retry..."
    sleep $wait_sec
    wait_sec=$((wait_sec * 2))
    rm -rf "$workdir" || true
  done

  echo "ERROR: Helm installation failed after ${tries} attempts."
  return 1
}

# call it
install_helm_with_retries || exit 1

# Verify helm is available; if not, dump installer logs and fail early
if ! command -v helm >/dev/null 2>&1; then
  echo "ERROR: 'helm' binary not found after installation attempts. Dumping installer logs for diagnosis..."
  for f in /tmp/helm_install_*.log; do
    if [ -f "$f" ]; then
      echo "---- $f ----"
      sed -n '1,200p' "$f"
    fi
  done
  echo "---- Diagnostics ----"
  uname -a || true
  echo "PATH=$PATH"
  ls -l /usr/local/bin | head -n 50 || true
  echo "---- End diagnostics ----"
  echo "Exiting because helm is required for subsequent steps.";
  exit 1
fi

# ============================================
# 6. Initialize the Control Plane
# ============================================
log_section_start "6. Initialize the Control Plane"
echo "--> Initializing the Kubernetes control plane..."

cat <<EOF | kubeadm init --upload-certs 
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
controlPlaneEndpoint: "k8s.lab.local:6443"
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

#kubeadm init --pod-network-cidr="$POD_NETWORK_CIDR"

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
# 10. Install MetalLB
# ============================================
log_section_start "10. Install MetalLB"
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
  - 192.168.0.45/32
EOF

# ============================================
# 11. Install Docker client tools - V2
# ============================================
log_section_start "11. Install Docker client tools"
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
# 12. Restart calico-node to ensure networking initializes cleanly
# ============================================

log_section_start "12. Restart calico-node to ensure networking initializes cleanly"
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
# 13. Setup MetalLB pool
# ============================================

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
sleep 30
kubectl apply -f metallb.yaml

# ============================================
# Installation Complete
# ============================================
log_section_start "Installation Complete"
kubectl get pods -n kube-system

echo " # =============================================== "
echo " "

# Print total script runtime
if [ -n "${SCRIPT_START_TS:-}" ]; then
  now_ts=$(date +%s)
  total_sec=$((now_ts - SCRIPT_START_TS))
  hrs=$((total_sec / 3600))
  mins=$(((total_sec % 3600) / 60))
  secs=$((total_sec % 60))
  printf "\nTotal script runtime: %02dh:%02dm:%02ds\n" "$hrs" "$mins" "$secs"
fi

echo " "
echo " "

# Export kubeconfig to current directory and print to screen
KUBECONF_SRC="/etc/kubernetes/admin.conf"
if [ -f "$KUBECONF_SRC" ]; then
  EXEC_DIR="$(pwd)"
  KUBECONF_OUT="$EXEC_DIR/kubeconfig"
  KUBECONF_CFG="$EXEC_DIR/kubeconfig.config"
  echo "Exporting kubeconfig to: $KUBECONF_OUT and $KUBECONF_CFG"
  cp "$KUBECONF_SRC" "$KUBECONF_OUT"
  cp "$KUBECONF_SRC" "$KUBECONF_CFG"
  chmod 600 "$KUBECONF_OUT" || true
  chmod 600 "$KUBECONF_CFG" || true
  echo "\n---- kubeconfig (begin) ----"
  sed -n '1,200p' "$KUBECONF_SRC"
  echo "---- kubeconfig (end) ----\n"
  echo " "

else
  echo "Warning: $KUBECONF_SRC not found; cannot export kubeconfig."
fi
echo " "


