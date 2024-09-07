#!/bin/bash
#LibreNMS-Docker-Install.sh
#remove any existing docker installation
#developed for ubuntu 24.04
echo "We are removing existing docker install"
sudo apt remove docker docker-engine docker.io containerd runc
# install prereq
echo "We are installing the prereq"
sudo apt install ca-certificates curl gnupg lsb-release
# downlod and inststall gpg key
echo "We are creating the key ring"
sudo mkdir -m 0755 -p /etc/apt/keyrings
echo "We are downloading the gpg key and installing it to the key ring" 
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
# add docker public repo to the apt package manager
echo "We are adding the docker public repo to the package mamanger"
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
# install docker from public repo
echo "We are installing docker"
sudo apt update
sudo apt install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl start docker
sudo systemctl status docker
sleep 5
# make the directorys
echo "We are creating the working directory"
sudo mkdir /opt/docker
sudo mkdir /opt/docker/librenms/
cd /opt/docker/librenms
echo "downloading the librenms container"
wget https://github.com/librenms/docker/archive/refs/heads/master.zip && unzip master.zip
cd ./docker-master/examples/compose
#start the container and run in the backgound
echo "We are starting the container"
sudo docker compose up -d
echo "The container startup is complete..."
echo "vist http://lan_ip_address:8000 for setup instructions"
