#!/bin/bash
set -euxo pipefail

KUBERNETES_VERSION="${kubernetes_version}"
GATEKEEPER_VERSION="${gatekeeper_version}"
LAB_DIR="/opt/w10-day1-rbac-gatekeeper"
ARCH="amd64"

yum update -y
yum install -y curl docker git jq
systemctl enable --now docker
usermod -aG docker ec2-user

curl -fsSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/$KUBERNETES_VERSION/bin/linux/$ARCH/kubectl"
chmod +x /usr/local/bin/kubectl

curl -fsSL -o /usr/local/bin/kind "https://kind.sigs.k8s.io/dl/v0.24.0/kind-linux-$ARCH"
chmod +x /usr/local/bin/kind

mkdir -p "$LAB_DIR/manifests"
chown -R ec2-user:ec2-user "$LAB_DIR"

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

if ! kind get clusters | grep -qx day1; then
  kind create cluster --name day1 --image "kindest/node:$KUBERNETES_VERSION"
fi

mkdir -p /home/ec2-user/.kube
kind get kubeconfig --name day1 > /home/ec2-user/.kube/config
chown -R ec2-user:ec2-user /home/ec2-user/.kube
export KUBECONFIG=/home/ec2-user/.kube/config

kubectl wait --for=condition=Ready nodes --all --timeout=180s
kubectl apply -f "$LAB_DIR/manifests/01-rbac.yaml"

kubectl apply -f "https://raw.githubusercontent.com/open-policy-agent/gatekeeper/$GATEKEEPER_VERSION/deploy/gatekeeper.yaml"
kubectl wait --for=condition=Available deployment/gatekeeper-controller-manager -n gatekeeper-system --timeout=300s

kubectl apply -f "$LAB_DIR/manifests/02-required-label-template.yaml"
kubectl wait --for=condition=Established crd/k8srequiredlabels.constraints.gatekeeper.sh --timeout=120s
kubectl apply -f "$LAB_DIR/manifests/03-required-label-constraint.yaml"

chown -R ec2-user:ec2-user "$LAB_DIR"
echo "W10 Day 1 lab is ready. Follow the repository file day1/README.md."
