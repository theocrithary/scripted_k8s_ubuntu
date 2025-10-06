#!/bin/bash

# ==============================================================================
# Single-Node Kubernetes Cluster Installation Script
#
# This script automates the full setup of a single-node Kubernetes cluster
# on an Ubuntu 22.04 server using kubeadm.
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
# Run with: sudo ./install-k8s.sh

# sudo ./install_k8s.sh -u <your_username> -p <your_password>
# ==============================================================================

#while getopts ":u:p:" opt; do
#  case $opt in
#    u) DOCKER_USERNAME="$OPTARG";;
#    p) DOCKER_PASSWORD="$OPTARG";;
#    \?) echo "Invalid option: -$OPTARG"; exit 1;;
#  esac
#done

set -e



# ================================
# 1. Define Cluster Variables
# ================================
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
echo "--> Installing Helm CLI..."
# Download and install the Helm CLI
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh
rm get_helm.sh

# ============================================
# 6. Initialize the Control Plane
# ============================================
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
echo "--> Configuring kubectl for the current user..."
mkdir -p "$HOME"/.kube
cp -i /etc/kubernetes/admin.conf "$HOME"/.kube/config
chown "$(id -u)":"$(id -g)" "$HOME"/.kube/config

# ============================================
# 8. Untaint the Control Plane Node (for single node setup)
# ============================================
echo "--> Untainting the master node to run pods..."
# Get the node name and untaint it
NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
kubectl taint nodes "$NODE_NAME" node-role.kubernetes.io/control-plane:NoSchedule-

# ============================================
# 9. Install a Pod Network Add-on (Calico)
# ============================================
echo "--> Deploying Calico Pod Network Add-on..."
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.5/manifests/calico.yaml

# ============================================
# 10. Install MetalLB
# ============================================
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

# Update package index and install Docker
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io

# Enable and start Docker service
systemctl enable --now docker

# Add current user to Docker group
usermod -aG docker $USER

# ============================================
# 12. Setup MetalLB pool
# ============================================

echo "--> Waiting for Kubernetes control-plane to become Ready..."

# Record the start time
START_TIME=$(date +%s)

# Loop until the control-plane node is Ready
until kubectl get nodes | grep -E 'control-plane.*Ready'; do
  CURRENT_TIME=$(date +%s)
  ELAPSED=$((CURRENT_TIME - START_TIME))
  MINUTES=$((ELAPSED / 60))
  SECONDS=$((ELAPSED % 60))
  echo "Still waiting... elapsed time: ${MINUTES}m ${SECONDS}s"
  sleep 5
done

echo "--> Control-plane is Ready after ${MINUTES}m ${SECONDS}s. Proceeding with MetalLB configuration..."

# Apply the MetalLB configuration
kubectl apply -f metallb.yaml

# ============================================
# Installation Complete
# ============================================

echo "========================================================"
echo "Kubernetes cluster installation is complete!"
echo "To verify the status of your nodes, run: kubectl get nodes"
echo "========================================================"