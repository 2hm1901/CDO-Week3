# W10 Day 2 Lab: Secrets Rotation + Supply Chain Security

Lab này giúp bạn hiểu hai nhóm kiến thức:

- Secrets management: giữ secret ở AWS Secrets Manager, sau đó sync vào Kubernetes bằng External Secrets Operator.
- Supply chain security: scan image bằng Trivy, fail CI khi có lỗ hổng critical, ký image bằng Cosign, verify signature và chặn image chưa ký nếu có thể.

## Mục tiêu bài lab

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

## Vì sao cần các thành phần này?

Kubernetes có object `Secret`, nhưng nếu bạn tự lưu secret trực tiếp trong YAML hoặc Git thì rất dễ lộ secret. Cách tốt hơn là để secret thật trong một secret manager chuyên dụng như AWS Secrets Manager, còn Kubernetes chỉ nhận bản sync cần thiết để workload chạy.

External Secrets Operator, gọi tắt là ESO, là controller chạy trong Kubernetes. Nó đọc secret từ AWS Secrets Manager rồi tạo Kubernetes Secret tương ứng. Nhờ vậy app vẫn dùng Kubernetes Secret như bình thường, nhưng source of truth nằm ở AWS.

Với supply chain, vấn đề không chỉ là app chạy được. Bạn cần biết image có lỗ hổng nghiêm trọng không, image có đúng do CI của repo ký không, và cluster có thể chặn image chưa ký không. Trivy, Cosign và policy admission giải quyết các lớp đó.

## Kiến trúc

Terraform Day 2 tạo một EC2 riêng chạy Amazon Linux 2023. EC2 này cài Docker, minikube và kubectl. Terraform cũng tạo AWS Secrets Manager secret và IAM user tối thiểu để ESO đọc secret.

Luồng secrets:

```text
AWS Secrets Manager
  -> IAM credentials cho ESO
  -> ClusterSecretStore
  -> ExternalSecret
  -> Kubernetes Secret app-config
  -> Pod/app có thể mount hoặc đọc secret
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

## Chạy ở đâu?

- Máy local: chạy Terraform, copy credentials script, push code lên GitHub.
- EC2 Day 2: chạy kubectl, minikube, cài ESO, tạo `ClusterSecretStore`, tạo `ExternalSecret`.
- GitHub Actions: build, scan, push, sign và verify image.

## 1. Triển khai EC2 và secret bằng Terraform

Vì sao cần bước này:

- Cần một Kubernetes cluster để cài ESO và test sync secret. Lab dùng minikube trên EC2.
- Cần AWS Secrets Manager secret làm nguồn secret thật.
- Cần IAM credentials để ESO có quyền đọc đúng secret đó.

Chạy trên máy local:

```bash
cd day2/terraform
terraform init
terraform apply -var='allowed_ssh_cidr=YOUR_PUBLIC_IP/32'
```

Ví dụ:

```bash
terraform apply -var='allowed_ssh_cidr=14.191.244.145/32'
```

Terraform tạo:

- EC2 Day 2 lab host chạy Docker + minikube.
- SSH key local trong `day2/terraform/generated/`.
- AWS Secrets Manager secret `w10/day2/demo-app`.
- IAM user chỉ có quyền `GetSecretValue` và `DescribeSecret` trên secret này.
- Script `day2/terraform/generated/create-eso-aws-credentials.sh` để tạo Kubernetes Secret chứa AWS credentials cho ESO.

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

Kết quả mong đợi trên EC2:

```bash
minikube status
kubectl get nodes
```

Bạn cần thấy node minikube ở trạng thái `Ready`.

## 1b. Tùy chọn: tạo secret bằng AWS Console

Bước này dành cho trường hợp bạn muốn nhìn trực tiếp AWS Secrets Manager trên Console thay vì để Terraform tạo toàn bộ.

Tạo secret trên Console:

1. Mở AWS Console.
2. Vào `AWS Secrets Manager`.
3. Chọn `Store a new secret`.
4. Chọn `Other type of secret`.
5. Thêm 3 key/value:
   - `username`: `demo-user`
   - `password`: `change-me-in-real-life`
   - `api_key`: `demo-api-key`
6. Secret name: `w10/day2/demo-app`.
7. Giữ các option mặc định cho rotation trong lab này.
8. Chọn `Store`.
9. Copy `Secret ARN`.

Vì sao cần import vào Terraform:

- Terraform cần biết ARN của secret để tạo IAM policy cho ESO.
- Nếu không import, Terraform sẽ cố tạo secret trùng tên và fail.

Import secret đã tạo thủ công:

```bash
cd day2/terraform
terraform init
terraform import aws_secretsmanager_secret.demo SECRET_ARN_FROM_CONSOLE
terraform apply -var='allowed_ssh_cidr=YOUR_PUBLIC_IP/32'
```

Lưu ý: nếu bạn import secret đã tạo từ Console, resource `aws_secretsmanager_secret_version.demo` trong Terraform vẫn sẽ ghi version mới theo payload trong `var.secret_payload`. Điều này chấp nhận được trong lab; production nên quản lý secret value bằng quy trình riêng.

## 2. Tạo Kubernetes Secret chứa AWS credentials cho ESO

Vì sao cần bước này:

ESO chạy trong minikube, không tự có quyền AWS. Trên EKS production thường dùng IRSA/Pod Identity. Trong lab minikube, cách đơn giản nhất là tạo một Kubernetes Secret chứa access key của IAM user read-only.

Copy script credentials từ máy local lên EC2. Chạy từ thư mục `day2/terraform` trên máy local:

```bash
$(terraform output -raw scp_credentials_command)
```

SSH lại vào EC2 nếu bạn chưa ở trong instance:

```bash
$(terraform output -raw ssh_command)
```

Tạo Kubernetes Secret chứa AWS credentials cho ESO:

```bash
chmod +x ~/create-eso-aws-credentials.sh
~/create-eso-aws-credentials.sh
kubectl get secret aws-secretsmanager-creds -n external-secrets
```

Kết quả mong đợi:

- Namespace `external-secrets` tồn tại.
- Secret `aws-secretsmanager-creds` tồn tại trong namespace `external-secrets`.

## 3. Cài External Secrets Operator

Vì sao cần bước này:

`ExternalSecret` và `ClusterSecretStore` không phải resource mặc định của Kubernetes. Chúng là CRD do External Secrets Operator cài vào cluster. Nếu chưa cài ESO, Kubernetes sẽ không hiểu các kind này hoặc sẽ không có controller nào sync secret.

Chạy trên EC2:

```bash
cd ~/CDO-Week3
git pull
bash day2/scripts/install-external-secrets.sh
```

Script này làm gì:

- Apply manifest chính thức của ESO.
- Kiểm tra namespace và deployments.
- Đợi 3 deployment sẵn sàng:
  - `external-secrets`
  - `external-secrets-webhook`
  - `external-secrets-cert-controller`
- Kiểm tra CRD của ESO.

Kết quả mong đợi:

```bash
kubectl get pods -n external-secrets
kubectl get deployment -n external-secrets
kubectl get crd | grep external-secrets
```

Nếu bạn gặp lỗi:

```text
Error from server (NotFound): deployments.apps "external-secrets" not found
```

nghĩa là ESO chưa được cài thật sự. Hãy chạy:

```bash
cd ~/CDO-Week3
git pull
bash day2/scripts/install-external-secrets.sh
```

## 4. Tạo ClusterSecretStore

Vì sao cần bước này:

`ClusterSecretStore` nói cho ESO biết phải đọc secret từ đâu và xác thực như thế nào. Trong lab này, store trỏ tới AWS Secrets Manager ở region `ap-southeast-2`, dùng Kubernetes Secret `aws-secretsmanager-creds` để lấy access key.

Chạy trên EC2:

```bash
cd ~/CDO-Week3
git pull
kubectl apply -f day2/manifests/02-cluster-secret-store.yaml
kubectl get clustersecretstore aws-secretsmanager
kubectl describe clustersecretstore aws-secretsmanager
```

Kết quả mong đợi:

- `ClusterSecretStore` tên `aws-secretsmanager` được tạo.
- Phần status không báo lỗi authentication.

Lưu ý: file [02-cluster-secret-store.yaml](manifests/02-cluster-secret-store.yaml) đang dùng region `ap-southeast-2`. Nếu bạn đổi `aws_region` trong Terraform, sửa `spec.provider.aws.region` cho khớp.

## 5. Tạo ExternalSecret và kiểm tra Kubernetes Secret

Vì sao cần bước này:

`ExternalSecret` là yêu cầu sync cụ thể. Nó nói: đọc secret `w10/day2/demo-app` từ AWS Secrets Manager, lấy các property `username`, `password`, `api_key`, rồi tạo Kubernetes Secret tên `app-config` trong namespace `dev`.

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

Ý nghĩa cốt lõi:

- App trong Kubernetes chỉ cần đọc `Secret/app-config`.
- Team platform vẫn quản lý secret thật ở AWS Secrets Manager.
- Khi secret trong AWS đổi, ESO có thể refresh lại Kubernetes Secret theo `refreshInterval`.

## 6. GitHub Actions scan image bằng Trivy

Vì sao cần bước này:

Trước khi image được push và deploy, CI nên kiểm tra lỗ hổng bảo mật. Nếu image có vulnerability mức critical, pipeline phải fail để tránh đưa artifact nguy hiểm vào registry.

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
- `exit-code: "1"` làm GitHub Actions step fail nếu tìm thấy lỗi phù hợp điều kiện.
- `ignore-unfixed: false` nghĩa là cả CVE chưa có bản vá vẫn làm CI fail nếu severity là `CRITICAL`.
- Job dừng trước khi push/sign image, nên image lỗi không vào registry.

## 8. Exception CVE bằng .trivyignore

Vì sao cần bước này:

Thực tế có lúc bạn biết một CVE không ảnh hưởng workload, hoặc chưa có fixed version nhưng rủi ro đã được chấp nhận tạm thời. `.trivyignore` cho phép tạo exception có kiểm soát.

File exception mẫu nằm ở [day2/app/.trivyignore](app/.trivyignore).

Ví dụ:

```text
# CVE được chấp nhận tạm thời vì chưa có fixed version, review lại sau.
CVE-2021-36159
```

Không nên dùng `.trivyignore` để bỏ qua lỗi tùy tiện. Mỗi exception nên có lý do, owner và ngày hết hạn trong comment hoặc ticket.

## 9. Ký và verify image bằng Cosign

Vì sao cần bước này:

Scan chỉ nói image có vulnerability hay không. Nó không chứng minh image đó do CI của repo bạn tạo ra. Cosign signature giúp chứng minh nguồn gốc image và phát hiện image bị thay thế hoặc push thủ công không qua pipeline.

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

Vì sao cần bước này:

Verify trong CI là tốt, nhưng cluster vẫn có thể bị ai đó deploy image chưa ký nếu admission không kiểm tra. Kyverno `verifyImages` cho phép Kubernetes API server từ chối image không có signature hợp lệ.

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

Vì sao cần bước này:

Terraform đã tạo EC2, IAM user/access key và Secrets Manager secret. Nếu không destroy, bạn sẽ tiếp tục tốn chi phí EC2 và giữ lại credentials không cần thiết.

Chạy trên máy local:

```bash
cd day2/terraform
terraform destroy
```
