#!/bin/bash
set -euo pipefail

# Cài External Secrets Operator từ manifest release chính thức.
# Script này fail sớm nếu manifest không tạo đủ Deployment mong đợi.
ESO_VERSION="v0.10.7"
ESO_URL="https://github.com/external-secrets/external-secrets/releases/download/${ESO_VERSION}/external-secrets.yaml"
TMP_MANIFEST="$(mktemp)"
trap 'rm -f "$TMP_MANIFEST"' EXIT

# Manifest release v0.10.7 hardcode ESO vào namespace default, bao gồm cả
# cert-controller args và webhook service reference. Lab giữ đúng namespace default
# để tránh cert-controller reconcile webhook quay lại default sau khi ta patch.
curl -fsSL "$ESO_URL" > "$TMP_MANIFEST"

# Xóa webhook configuration cũ trước khi apply lại. Nếu trước đó manifest từng được cài
# ở namespace default, webhook có thể vẫn trỏ tới external-secrets-webhook.default.svc.
kubectl delete validatingwebhookconfiguration secretstore-validate externalsecret-validate \
  --ignore-not-found

kubectl apply -f "$TMP_MANIFEST"

# Nếu trước đó bạn đã thử cài ESO vào namespace external-secrets, xóa các workload đó
# để tránh có hai bộ controller cùng chạy trong lab.
kubectl delete deployment external-secrets external-secrets-webhook external-secrets-cert-controller \
  -n external-secrets --ignore-not-found
kubectl delete serviceaccount external-secrets external-secrets-webhook external-secrets-cert-controller \
  -n external-secrets --ignore-not-found
kubectl delete service external-secrets-webhook \
  -n external-secrets --ignore-not-found

kubectl get deployment -n default | grep external-secrets

kubectl wait --for=condition=Available deployment/external-secrets -n default --timeout=300s
kubectl wait --for=condition=Available deployment/external-secrets-webhook -n default --timeout=300s
kubectl wait --for=condition=Available deployment/external-secrets-cert-controller -n default --timeout=300s

kubectl get pods -n default | grep external-secrets
kubectl get crd | grep external-secrets
