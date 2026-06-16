#!/bin/bash
set -euo pipefail

# Cài External Secrets Operator từ manifest release chính thức.
# Script này fail sớm nếu manifest không tạo đủ Deployment mong đợi.
ESO_VERSION="v0.10.7"
ESO_URL="https://github.com/external-secrets/external-secrets/releases/download/${ESO_VERSION}/external-secrets.yaml"
TMP_MANIFEST="$(mktemp)"
trap 'rm -f "$TMP_MANIFEST"' EXIT

# Manifest release v0.10.7 hardcode một số object namespaced vào namespace default.
# Với lab này, ta rewrite namespace đó sang external-secrets để mọi Deployment/ServiceAccount
# nằm cùng namespace với credentials Secret aws-secretsmanager-creds.
kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f -
curl -fsSL "$ESO_URL" | sed 's/namespace: default/namespace: external-secrets/g' > "$TMP_MANIFEST"
kubectl apply -f "$TMP_MANIFEST"

# Nếu trước đó bạn đã apply manifest cũ vào namespace default, xóa các workload ESO ở default
# để tránh có hai bộ controller cùng chạy trong lab.
kubectl delete deployment external-secrets external-secrets-webhook external-secrets-cert-controller \
  -n default --ignore-not-found
kubectl delete serviceaccount external-secrets external-secrets-webhook external-secrets-cert-controller \
  -n default --ignore-not-found
kubectl delete service external-secrets-webhook \
  -n default --ignore-not-found

kubectl get namespace external-secrets
kubectl get deployment -n external-secrets

kubectl wait --for=condition=Available deployment/external-secrets -n external-secrets --timeout=300s
kubectl wait --for=condition=Available deployment/external-secrets-webhook -n external-secrets --timeout=300s
kubectl wait --for=condition=Available deployment/external-secrets-cert-controller -n external-secrets --timeout=300s

kubectl get pods -n external-secrets
kubectl get crd | grep external-secrets
