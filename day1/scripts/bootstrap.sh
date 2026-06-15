#!/bin/bash
set -euxo pipefail

# Các biến này được Terraform render vào script bằng templatefile().
KUBERNETES_VERSION="${kubernetes_version}"
GATEKEEPER_VERSION="${gatekeeper_version}"
LAB_DIR="/opt/w10-day1-rbac-gatekeeper"
ARCH="amd64"

# Cài package nền tảng. Amazon Linux 2023 có sẵn curl-minimal,
# đủ dùng cho download bên dưới; không cài package curl để tránh conflict.
yum update -y
yum install -y docker git jq
systemctl enable --now docker
usermod -aG docker ec2-user

# Cài kubectl đúng version Kubernetes mà minikube sẽ chạy.
curl -fsSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/$KUBERNETES_VERSION/bin/linux/$ARCH/kubectl"
chmod +x /usr/local/bin/kubectl

# Cài minikube. Lab dùng Docker driver nên không cần hypervisor/VM driver.
curl -fsSL -o /usr/local/bin/minikube "https://storage.googleapis.com/minikube/releases/latest/minikube-linux-$ARCH"
chmod +x /usr/local/bin/minikube

# Manifest được ghi ra /opt để người học có thể mở xem và chạy lại bằng kubectl.
mkdir -p "$LAB_DIR/manifests"
chown -R ec2-user:ec2-user "$LAB_DIR"

# RBAC lab: tạo namespace dev, service account viewer, Role chỉ đọc pod,
# và RoleBinding gán Role đó cho service account.
cat > "$LAB_DIR/manifests/01-rbac.yaml" <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: dev
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: viewer
  namespace: dev
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-reader
  namespace: dev
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: viewer-pod-reader
  namespace: dev
subjects:
  - kind: ServiceAccount
    name: viewer
    namespace: dev
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: pod-reader
YAML

# Gatekeeper ConstraintTemplate: định nghĩa kind policy K8sRequiredLabels.
# Rego bên dưới so sánh labels bắt buộc với labels hiện có trên object.
cat > "$LAB_DIR/manifests/02-required-label-template.yaml" <<'YAML'
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8srequiredlabels
spec:
  crd:
    spec:
      names:
        kind: K8sRequiredLabels
      validation:
        openAPIV3Schema:
          type: object
          properties:
            labels:
              type: array
              items:
                type: string
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8srequiredlabels

        violation[{"msg": msg}] {
          required := {label | label := input.parameters.labels[_]}
          provided := {label | input.review.object.metadata.labels[label]}
          missing := required - provided
          count(missing) > 0
          msg := sprintf("missing required labels: %v", [missing])
        }
YAML

# Constraint áp dụng template ở trên cho Pod trong namespace dev.
# enforcementAction deny nghĩa là request vi phạm sẽ bị API server từ chối.
cat > "$LAB_DIR/manifests/03-required-label-constraint.yaml" <<'YAML'
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sRequiredLabels
metadata:
  name: dev-pods-must-have-app-label
spec:
  enforcementAction: deny
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
    namespaces:
      - dev
  parameters:
    labels:
      - app
YAML

# Pod cố tình thiếu label app để kiểm tra Gatekeeper deny.
cat > "$LAB_DIR/manifests/pod-missing-label.yaml" <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: missing-label
  namespace: dev
spec:
  containers:
    - name: nginx
      image: nginx:1.27-alpine
YAML

# Pod hợp lệ có label app, dùng để chứng minh policy không chặn sai.
cat > "$LAB_DIR/manifests/pod-with-label.yaml" <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: with-label
  namespace: dev
  labels:
    app: nginx
spec:
  containers:
    - name: nginx
      image: nginx:1.27-alpine
YAML

# Tạo minikube cluster bằng Docker driver dưới user ec2-user.
# Chạy bằng ec2-user giúp kubeconfig nằm đúng trong /home/ec2-user/.kube/config.
sudo -u ec2-user -H minikube start \
  --driver=docker \
  --kubernetes-version="$KUBERNETES_VERSION" \
  --container-runtime=docker

# Dùng kubeconfig của ec2-user cho các lệnh kubectl chạy trong bootstrap.
export KUBECONFIG=/home/ec2-user/.kube/config

# Đợi node sẵn sàng rồi apply phần RBAC của lab.
kubectl wait --for=condition=Ready nodes --all --timeout=180s
kubectl apply -f "$LAB_DIR/manifests/01-rbac.yaml"

# Cài OPA Gatekeeper từ manifest release chính thức và đợi controller sẵn sàng.
kubectl apply -f "https://raw.githubusercontent.com/open-policy-agent/gatekeeper/$GATEKEEPER_VERSION/deploy/gatekeeper.yaml"
kubectl wait --for=condition=Available deployment/gatekeeper-controller-manager -n gatekeeper-system --timeout=300s

# Apply ConstraintTemplate trước để Kubernetes tạo CRD K8sRequiredLabels,
# sau đó mới apply Constraint instance.
kubectl apply -f "$LAB_DIR/manifests/02-required-label-template.yaml"
kubectl wait --for=condition=Established crd/k8srequiredlabels.constraints.gatekeeper.sh --timeout=120s
kubectl apply -f "$LAB_DIR/manifests/03-required-label-constraint.yaml"

# Đảm bảo ec2-user đọc được toàn bộ manifest sau khi bootstrap hoàn tất.
chown -R ec2-user:ec2-user "$LAB_DIR"
echo "W10 Day 1 lab is ready. Follow the repository file day1/README.md."
