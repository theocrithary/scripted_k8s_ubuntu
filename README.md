## Tested with Ubuntu 22.04

## Single Node k8s

### Download and create install-k8s.sh file
```
curl -LO https://github.com/theocrithary/scripted_k8s_ubuntu/raw/refs/heads/main/install-k8s.sh
sudo chmod +x install-k8s.sh
```
### Edit all applicable IP addresses, hostnames and other user variables to your environment
```
sudo vi install-k8s.sh
```
### Add your Docker user creds to local environment variables to avoid pull limits
```
export DOCKER_USER=your_dockerhub_username
export DOCKER_TOKEN=your_personal_access_token
```
### Run the script
```
sudo -E ./install-k8s.sh
```


