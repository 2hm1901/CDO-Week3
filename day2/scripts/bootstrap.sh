#!/bin/bash
set -euxo pipefail

# Terraform render version Kubernetes vào script này bằng templatefile().
KUBERNETES_VERSION="${kubernetes_version}"
ARCH="amd64"
REPO_URL="https://github.com/2hm1901/CDO-Week3.git"
REPO_DIR="/home/ec2-user/CDO-Week3"

# Amazon Linux 2023 có sẵn curl-minimal; không cài package curl để tránh conflict.
yum update -y
yum install -y docker git jq
systemctl enable --now docker
usermod -aG docker ec2-user

# kubectl dùng để thao tác với minikube cluster.
curl -fsSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/$KUBERNETES_VERSION/bin/linux/$ARCH/kubectl"
chmod +x /usr/local/bin/kubectl

# Minikube chạy bằng Docker driver trên EC2.
curl -fsSL -o /usr/local/bin/minikube "https://storage.googleapis.com/minikube/releases/latest/minikube-linux-$ARCH"
chmod +x /usr/local/bin/minikube

# Clone repo để có sẵn README, manifest và Dockerfile mẫu trên EC2.
if [ ! -d "$REPO_DIR/.git" ]; then
  sudo -u ec2-user -H git clone "$REPO_URL" "$REPO_DIR"
else
  sudo -u ec2-user -H git -C "$REPO_DIR" pull --ff-only
fi

# Tạo minikube cluster dưới user ec2-user để kubeconfig nằm đúng home directory.
sudo -u ec2-user -H minikube start \
  --driver=docker \
  --kubernetes-version="$KUBERNETES_VERSION" \
  --container-runtime=docker

export KUBECONFIG=/home/ec2-user/.kube/config
kubectl wait --for=condition=Ready nodes --all --timeout=180s

chown -R ec2-user:ec2-user "$REPO_DIR"
echo "W10 Day 2 lab host is ready. Follow /home/ec2-user/CDO-Week3/day2/README.md."
