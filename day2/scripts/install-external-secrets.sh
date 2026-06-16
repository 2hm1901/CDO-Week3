#!/bin/bash
set -euo pipefail

# Cài External Secrets Operator từ manifest release chính thức.
# Script này fail sớm nếu manifest không tạo đủ Deployment mong đợi.
ESO_VERSION="v0.10.7"
ESO_URL="https://github.com/external-secrets/external-secrets/releases/download/${ESO_VERSION}/external-secrets.yaml"

# Manifest release không tự đảm bảo mọi namespaced resource đi vào namespace
# external-secrets trong mọi context, nên tạo namespace trước và apply với -n.
kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n external-secrets -f "$ESO_URL"

kubectl get namespace external-secrets
kubectl get deployment -n external-secrets

kubectl wait --for=condition=Available deployment/external-secrets -n external-secrets --timeout=300s
kubectl wait --for=condition=Available deployment/external-secrets-webhook -n external-secrets --timeout=300s
kubectl wait --for=condition=Available deployment/external-secrets-cert-controller -n external-secrets --timeout=300s

kubectl get pods -n external-secrets
kubectl get crd | grep external-secrets
