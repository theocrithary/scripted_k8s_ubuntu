apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
controlPlaneEndpoint: "k8s-vip.lab.local:6443"
kubernetesVersion: v1.30.14
networking:
  podSubnet: 161.200.0.0/16
  serviceSubnet: 161.210.0.0/16
apiServer:
  certSANs:
    - "k8s-1.lab.local"
    - "k8s-2.lab.local"
    - "k8s-3.lab.local"
    - "k8s-vip.lab.local"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
serverTLSBootstrap: true
maxPods: 180


docker run --network host --rm ghcr.io/kube-vip/kube-vip:v0.8.3 manifest pod --interface ens33 --vip 192.168.0.29 --controlplane --services --arp --leaderElection | sudo tee /etc/kubernetes/manifests/kube-vip.yaml

apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
controlPlaneEndpoint: "$HOST_NAME:6443"
kubernetesVersion: $KUBE_VERSION
networking:
    podSubnet: 161.200.0.0/16
    serviceSubnet: 161.210.0.0/16
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
serverTLSBootstrap: true
maxPods: 150


cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: longhorn-nodeport-svc
  namespace: longhorn-system
spec:
  type: NodePort
  ports:
    - name: http
      nodePort: 31000
      port: 80
      protocol: TCP
      targetPort: http
  selector:
    app: longhorn-ui
  sessionAffinity: None
EOF


helm repo update


controller:
  image:
    repository: haproxytech/kubernetes-ingress
    pullPolicy: Always
  imagePullSecrets:
    - name: docker-secret
  service:
    type: LoadBalancer
    externalTrafficPolicy: Local
  config:
    ssl-passthrough: "true"
  hostNetwork: true
  kind: DaemonSet
  defaultTLSSecret:
    enabled: false

helm install haproxy haproxytech/kubernetes-ingress --namespace haproxy --create-namespace -f haproxy.yaml

kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml

curl -LO https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml