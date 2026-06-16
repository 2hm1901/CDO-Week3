#!/bin/bash
set -euo pipefail

# Cài External Secrets Operator từ manifest release chính thức.
# Script này fail sớm nếu manifest không tạo đủ Deployment mong đợi.
ESO_VERSION="v0.10.7"
ESO_URL="https://github.com/external-secrets/external-secrets/releases/download/${ESO_VERSION}/external-secrets.yaml"
TMP_MANIFEST="$(mktemp)"
trap 'rm -f "$TMP_MANIFEST"' EXIT

# Manifest release v0.10.7 hardcode một số object và cert-controller args vào namespace default.
# Với lab này, ta rewrite namespace đó sang external-secrets để Deployment/ServiceAccount/Service,
# webhook service reference và certificate Secret nằm cùng namespace.
kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f -
curl -fsSL "$ESO_URL" \
  | sed \
      -e 's/namespace: default/namespace: external-secrets/g' \
      -e 's/--service-namespace=default/--service-namespace=external-secrets/g' \
      -e 's/--secret-namespace=default/--secret-namespace=external-secrets/g' \
  > "$TMP_MANIFEST"

# Xóa webhook configuration cũ trước khi apply lại. Nếu trước đó manifest từng được cài
# ở namespace default, webhook có thể vẫn trỏ tới external-secrets-webhook.default.svc.
kubectl delete validatingwebhookconfiguration secretstore-validate externalsecret-validate \
  --ignore-not-found

kubectl apply -f "$TMP_MANIFEST"

# Một số field trong ValidatingWebhookConfiguration vẫn có thể giữ
# clientConfig.service.namespace=default. Patch trực tiếp để admission webhook
# gọi đúng service external-secrets-webhook trong namespace external-secrets.
for webhook_config in secretstore-validate externalsecret-validate; do
  kubectl get validatingwebhookconfiguration "$webhook_config" -o json \
    | jq '(.webhooks[].clientConfig.service.namespace) = "external-secrets"' \
    | kubectl apply -f -
done

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
