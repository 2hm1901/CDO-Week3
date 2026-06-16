# W10 Day 2 Lab: Secrets Rotation + Supply Chain Security

Mục tiêu bài lab:

- Tạo secret trong AWS Secrets Manager.
- Cài External Secrets Operator.
- Tạo `ClusterSecretStore`.
- Tạo `ExternalSecret`.
- Kiểm tra Kubernetes Secret được tạo.
- Tạo GitHub Actions workflow scan image bằng Trivy.
- Cấu hình fail CI khi có critical vulnerability.
- Ký image bằng Cosign.
- Verify image signature.
- Tạo policy chặn unsigned image nếu có thể.
- Tạo ví dụ exception CVE bằng `.trivyignore`.

## Kiến trúc

Lab này dùng lại minikube trên EC2 của Day 1. Terraform Day 2 chỉ tạo phần AWS Secrets Manager và IAM user tối thiểu để External Secrets Operator đọc secret.

Luồng chính:

```text
AWS Secrets Manager
  -> External Secrets Operator
  -> ExternalSecret
  -> Kubernetes Secret app-config
```

Luồng supply chain:

```text
Dockerfile
  -> GitHub Actions build image
  -> Trivy scan
  -> push image nếu scan pass
  -> Cosign keyless sign
  -> Cosign verify
  -> optional Kyverno verifyImages policy
```

## 1. Tạo secret trong AWS Secrets Manager

Chạy trên máy local:

```bash
cd day2/terraform
terraform init
terraform apply
```

Xem tên secret:

```bash
terraform output secret_name
terraform output aws_region
```

Terraform tạo:

- AWS Secrets Manager secret `w10/day2/demo-app`.
- IAM user chỉ có quyền `GetSecretValue` và `DescribeSecret` trên secret này.
- Script local trong `day2/terraform/generated/create-eso-aws-credentials.sh` để tạo Kubernetes Secret chứa AWS credentials cho ESO.

## 2. Chuẩn bị credentials cho External Secrets Operator

Copy script credentials từ máy local lên EC2 Day 1:

```bash
scp -i ../../day1/terraform/generated/w10-day1-rbac-gatekeeper.pem \
  ./generated/create-eso-aws-credentials.sh \
  ec2-user@EC2_PUBLIC_IP:/home/ec2-user/create-eso-aws-credentials.sh
```

SSH vào EC2:

```bash
ssh -i ../../day1/terraform/generated/w10-day1-rbac-gatekeeper.pem ec2-user@EC2_PUBLIC_IP
```

Kiểm tra minikube:

```bash
minikube status
kubectl get nodes
```

Tạo Kubernetes Secret chứa AWS credentials cho ESO:

```bash
chmod +x ~/create-eso-aws-credentials.sh
~/create-eso-aws-credentials.sh
kubectl get secret aws-secretsmanager-creds -n external-secrets
```

## 3. Cài External Secrets Operator

Chạy trên EC2:

```bash
kubectl apply -f https://github.com/external-secrets/external-secrets/releases/download/v0.10.7/external-secrets.yaml
kubectl wait --for=condition=Available deployment/external-secrets -n external-secrets --timeout=300s
kubectl wait --for=condition=Available deployment/external-secrets-webhook -n external-secrets --timeout=300s
kubectl wait --for=condition=Available deployment/external-secrets-cert-controller -n external-secrets --timeout=300s
```

Kiểm tra:

```bash
kubectl get pods -n external-secrets
kubectl get crd | grep external-secrets
```

## 4. Tạo ClusterSecretStore

Copy manifest Day 2 lên EC2 hoặc `git pull` trên EC2 nếu bạn clone repo ở đó. Sau đó chạy:

```bash
kubectl apply -f day2/manifests/02-cluster-secret-store.yaml
kubectl get clustersecretstore aws-secretsmanager
kubectl describe clustersecretstore aws-secretsmanager
```

Lưu ý: file [02-cluster-secret-store.yaml](manifests/02-cluster-secret-store.yaml) đang dùng region `ap-southeast-2`. Nếu bạn đổi `aws_region` trong Terraform, sửa `spec.provider.aws.region` cho khớp.

## 5. Tạo ExternalSecret và kiểm tra Kubernetes Secret

Chạy trên EC2:

```bash
kubectl apply -f day2/manifests/03-external-secret.yaml
kubectl get externalsecret -n dev
kubectl describe externalsecret demo-app-config -n dev
kubectl get secret app-config -n dev
```

Decode secret để kiểm tra nội dung:

```bash
kubectl get secret app-config -n dev -o jsonpath='{.data.username}' | base64 -d; echo
kubectl get secret app-config -n dev -o jsonpath='{.data.password}' | base64 -d; echo
kubectl get secret app-config -n dev -o jsonpath='{.data.api_key}' | base64 -d; echo
```

Kết quả mong đợi:

- `ExternalSecret` có trạng thái ready.
- Kubernetes Secret `app-config` được tạo trong namespace `dev`.
- Giá trị decode khớp payload trong AWS Secrets Manager.

## 6. GitHub Actions scan image bằng Trivy

Workflow nằm ở [.github/workflows/day2-supply-chain.yml](../.github/workflows/day2-supply-chain.yml).

Workflow làm các bước:

- Build image từ [day2/app/Dockerfile](app/Dockerfile).
- Scan image bằng Trivy.
- Fail CI nếu có vulnerability severity `CRITICAL`.
- Push image lên GHCR nếu scan pass.
- Ký image bằng Cosign keyless.
- Verify signature bằng Cosign.

Lưu ý: [day2/app/Dockerfile](app/Dockerfile) cố tình dùng base image cũ để bạn thấy CI fail ở bước Trivy. Sau khi quan sát fail, bạn có thể nâng base image lên version mới hơn hoặc thêm exception CVE có kiểm soát vào `.trivyignore` để workflow đi tiếp tới bước push/sign/verify.

Trigger workflow thủ công trong GitHub:

```text
GitHub repo -> Actions -> Day 2 Supply Chain Security -> Run workflow
```

Hoặc push thay đổi vào `day2/app/**`.

## 7. Fail CI khi có critical vulnerability

Trong workflow:

```yaml
severity: CRITICAL
exit-code: "1"
ignore-unfixed: true
```

Ý nghĩa:

- Trivy chỉ xét vulnerability mức `CRITICAL`.
- Nếu tìm thấy critical vulnerability, step scan trả exit code `1`.
- Job dừng trước khi push/sign image.

## 8. Exception CVE bằng .trivyignore

File exception mẫu nằm ở [day2/app/.trivyignore](app/.trivyignore).

Ví dụ:

```text
# CVE được chấp nhận tạm thời vì chưa có fixed version, review lại sau.
CVE-2021-36159
```

Không nên dùng `.trivyignore` để bỏ qua lỗi tùy tiện. Mỗi exception nên có lý do, owner và ngày hết hạn trong comment hoặc ticket.

## 9. Ký và verify image bằng Cosign

Workflow dùng keyless signing, không cần lưu private key trong GitHub Secrets.

Ký:

```bash
cosign sign --yes "$IMAGE"
```

Verify:

```bash
cosign verify \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
  --certificate-identity-regexp="https://github.com/OWNER/REPO/.github/workflows/day2-supply-chain.yml@refs/heads/.*" \
  "$IMAGE"
```

Ý nghĩa:

- GitHub Actions cấp OIDC token.
- Cosign dùng token đó để ký image.
- Verify kiểm tra signature được phát hành bởi GitHub Actions workflow hợp lệ.

## 10. Optional: chặn unsigned image bằng Kyverno

Kubernetes/Gatekeeper không tự verify Cosign signature nếu không có tích hợp thêm. Cách thực tế và gọn cho lab là dùng Kyverno `verifyImages`.

Cài Kyverno trên EC2:

```bash
kubectl apply -f https://github.com/kyverno/kyverno/releases/download/v1.12.6/install.yaml
kubectl wait --for=condition=Available deployment/kyverno-admission-controller -n kyverno --timeout=300s
```

Apply policy:

```bash
kubectl apply -f day2/manifests/04-kyverno-verify-image-policy.yaml
kubectl get clusterpolicy require-cosign-signature
```

Policy này yêu cầu image `ghcr.io/*` phải có Cosign keyless signature từ GitHub Actions. Image chưa ký hoặc signature không đúng issuer/subject sẽ bị admission controller từ chối.

## Dọn dẹp

Chạy trên máy local:

```bash
cd day2/terraform
terraform destroy
```
