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

Lab này độc lập với Day 1. Terraform Day 2 tạo một EC2 Amazon Linux 2023 riêng, cài Docker/minikube/kubectl, đồng thời tạo AWS Secrets Manager secret và IAM user tối thiểu để External Secrets Operator đọc secret.

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

## 1. Triển khai EC2 và secret bằng Terraform

Chạy trên máy local:

```bash
cd day2/terraform
terraform init
terraform apply -var='allowed_ssh_cidr=YOUR_PUBLIC_IP/32'
```

Ví dụ nếu public IP của bạn là `14.191.244.145`:

```bash
terraform apply -var='allowed_ssh_cidr=14.191.244.145/32'
```

Terraform tạo:

- EC2 Day 2 lab host chạy Docker + minikube.
- SSH key local trong `day2/terraform/generated/`.
- AWS Secrets Manager secret `w10/day2/demo-app`.
- IAM user chỉ có quyền `GetSecretValue` và `DescribeSecret` trên secret này.
- Script local trong `day2/terraform/generated/create-eso-aws-credentials.sh` để tạo Kubernetes Secret chứa AWS credentials cho ESO.

Xem output:

```bash
terraform output secret_name
terraform output aws_region
terraform output -raw ssh_command
```

SSH vào EC2:

```bash
$(terraform output -raw ssh_command)
```

Nếu cloud-init chưa chạy xong:

```bash
sudo tail -f /var/log/cloud-init-output.log
```

Kiểm tra minikube trên EC2:

```bash
minikube status
kubectl get nodes
```

## 1b. Tùy chọn: tạo secret bằng AWS Console

Nếu muốn tự tạo secret trên AWS Console thay vì để Terraform tạo secret:

1. Mở AWS Console.
2. Vào `AWS Secrets Manager`.
3. Chọn `Store a new secret`.
4. Chọn `Other type of secret`.
5. Thêm 3 key/value:
   - `username`: `demo-user`
   - `password`: `change-me-in-real-life`
   - `api_key`: `demo-api-key`
6. Secret name: `w10/day2/demo-app`
7. Giữ các option mặc định cho rotation trong lab này.
8. Chọn `Store`.

Sau khi tạo bằng Console, copy `Secret ARN`, rồi import secret đó vào Terraform state trước khi `terraform apply`. Việc import giúp Terraform quản lý IAM policy đúng ARN và không cố tạo secret trùng tên:

```bash
cd day2/terraform
terraform init
terraform import aws_secretsmanager_secret.demo SECRET_ARN_FROM_CONSOLE
terraform apply -var='allowed_ssh_cidr=YOUR_PUBLIC_IP/32'
```

Lưu ý: nếu bạn import secret đã tạo từ Console, resource `aws_secretsmanager_secret_version.demo` trong Terraform vẫn sẽ ghi version mới theo payload trong `var.secret_payload`. Đây là hành vi chấp nhận được cho lab; production nên quản lý secret value bằng quy trình riêng.

## 2. Chuẩn bị credentials cho External Secrets Operator

Copy script credentials từ máy local lên EC2 Day 2. Chạy từ thư mục `day2/terraform`:

```bash
$(terraform output -raw scp_credentials_command)
```

SSH lại vào EC2 nếu bạn chưa ở trong instance:

```bash
$(terraform output -raw ssh_command)
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
cd ~/CDO-Week3
git pull
bash day2/scripts/install-external-secrets.sh
```

Nếu bạn gặp lỗi:

```bash
Error from server (NotFound): deployments.apps "external-secrets" not found
```

nghĩa là ESO chưa được cài thật sự. Nguyên nhân hay gặp là apply nhầm file cũ `day2/manifests/01-install-external-secrets.yaml`, file đó trước đây chỉ là note và không tạo Deployment. Hãy chạy lại script `day2/scripts/install-external-secrets.sh`.

## 4. Tạo ClusterSecretStore

Bootstrap đã clone repo vào `/home/ec2-user/CDO-Week3`. Chạy trên EC2:

```bash
cd ~/CDO-Week3
git pull
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
ignore-unfixed: false
```

Ý nghĩa:

- Trivy chỉ xét vulnerability mức `CRITICAL`.
- `ignore-unfixed: false` nghĩa là cả CVE chưa có bản vá vẫn làm CI fail nếu severity là `CRITICAL`.
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
