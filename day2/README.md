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
- Tạo namespace `external-secrets` nếu chưa tồn tại.
- Apply manifest với `-n external-secrets` để các Deployment/ServiceAccount/Service nằm đúng namespace.
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

Nếu trước đó bạn đã apply manifest mà quên `-n external-secrets`, có thể các resource đã nằm ở namespace `default`. Kiểm tra bằng:

```bash
kubectl get deployment -A | grep external-secrets
```

Sau khi pull bản mới, chạy lại script ở trên. Script sẽ tạo đúng các Deployment trong namespace `external-secrets`.

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

## 11. Kịch bản test kiến thức cốt lõi

Các kịch bản này không chỉ để kiểm tra “lab chạy được”, mà để bạn thấy rõ từng cơ chế Day 2 hoạt động như thế nào.

### Test 1: AWS Secrets Manager là source of truth

Học được gì:

- Secret thật nằm ở AWS Secrets Manager.
- Kubernetes Secret `app-config` là bản sync do ESO tạo ra.
- App trong cluster không cần biết AWS Secrets Manager, chỉ cần đọc Kubernetes Secret.

Chạy trên EC2:

```bash
kubectl get externalsecret demo-app-config -n dev
kubectl get secret app-config -n dev
kubectl get secret app-config -n dev -o jsonpath='{.data.username}' | base64 -d; echo
kubectl get secret app-config -n dev -o jsonpath='{.data.password}' | base64 -d; echo
kubectl get secret app-config -n dev -o jsonpath='{.data.api_key}' | base64 -d; echo
```

Kết quả mong đợi:

- `ExternalSecret` ở trạng thái ready.
- `Secret/app-config` tồn tại.
- Giá trị decode khớp secret trong AWS Secrets Manager.

### Test 2: Secret rotation được sync về Kubernetes

Học được gì:

- Khi secret trong AWS thay đổi, ESO có thể refresh Kubernetes Secret.
- `refreshInterval: 1m` trong `ExternalSecret` quyết định chu kỳ ESO kiểm tra lại remote secret.

Chạy trên máy local để đổi secret trong AWS:

```bash
aws secretsmanager put-secret-value \
  --region ap-southeast-2 \
  --secret-id w10/day2/demo-app \
  --secret-string '{"username":"demo-user","password":"rotated-password","api_key":"rotated-api-key"}'
```

Chạy trên EC2:

```bash
sleep 90
kubectl get secret app-config -n dev -o jsonpath='{.data.password}' | base64 -d; echo
kubectl get secret app-config -n dev -o jsonpath='{.data.api_key}' | base64 -d; echo
```

Kết quả mong đợi:

- Password đổi thành `rotated-password`.
- API key đổi thành `rotated-api-key`.

Ý nghĩa:

- Bạn không cần sửa YAML Kubernetes khi rotate secret.
- App đọc Kubernetes Secret có thể nhận giá trị mới theo cách app reload config của nó.

### Test 3: IAM permission sai làm sync fail

Học được gì:

- ESO không có quyền AWS mặc định.
- `ClusterSecretStore` phụ thuộc vào credentials trong `Secret/aws-secretsmanager-creds`.
- Nếu credentials sai, `ExternalSecret` không thể sync.

Chạy trên EC2 để cố tình làm sai secret access key:

```bash
kubectl create secret generic aws-secretsmanager-creds \
  --namespace external-secrets \
  --from-literal=access-key='invalid' \
  --from-literal=secret-access-key='invalid' \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl delete secret app-config -n dev --ignore-not-found
kubectl annotate externalsecret demo-app-config -n dev force-sync="$(date +%s)" --overwrite
sleep 30
kubectl describe externalsecret demo-app-config -n dev
kubectl get secret app-config -n dev
```

Kết quả mong đợi:

- `kubectl describe externalsecret` có lỗi authentication hoặc access denied.
- `Secret/app-config` không được tạo lại.

Khôi phục:

```bash
~/create-eso-aws-credentials.sh
kubectl annotate externalsecret demo-app-config -n dev force-sync="$(date +%s)" --overwrite
sleep 30
kubectl get secret app-config -n dev
```

Kết quả mong đợi sau khi khôi phục:

- `Secret/app-config` được tạo lại.

### Test 4: ExternalSecret sai remote key làm sync fail

Học được gì:

- `ExternalSecret.spec.data[].remoteRef.key` phải trỏ đúng secret name trong AWS.
- ESO báo lỗi ở status/condition khi remote secret không tồn tại.

Chạy trên EC2:

```bash
kubectl patch externalsecret demo-app-config -n dev \
  --type='json' \
  -p='[{"op":"replace","path":"/spec/data/0/remoteRef/key","value":"w10/day2/not-found"}]'

kubectl annotate externalsecret demo-app-config -n dev force-sync="$(date +%s)" --overwrite
sleep 30
kubectl describe externalsecret demo-app-config -n dev
```

Kết quả mong đợi:

- `ExternalSecret` báo lỗi không tìm thấy remote secret.

Khôi phục:

```bash
kubectl apply -f day2/manifests/03-external-secret.yaml
kubectl annotate externalsecret demo-app-config -n dev force-sync="$(date +%s)" --overwrite
sleep 30
kubectl get secret app-config -n dev
```

### Test 5: Trivy gate chặn image có critical vulnerability

Học được gì:

- CI phải chặn image nguy hiểm trước khi push/sign.
- `exit-code: "1"` biến kết quả scan thành policy gate.

Chạy trên GitHub:

```text
GitHub repo -> Actions -> Day 2 Supply Chain Security -> Run workflow
```

Kết quả mong đợi với Dockerfile hiện tại:

- Workflow fail ở step `Scan image with Trivy and fail on critical vulnerabilities` nếu image có CVE critical.
- Các step push/sign/verify không chạy.

Ý nghĩa:

- Image chưa đạt yêu cầu bảo mật không được đưa vào registry.

### Test 6: .trivyignore là exception có kiểm soát

Học được gì:

- Không phải CVE nào cũng xử lý ngay được.
- `.trivyignore` cho phép exception, nhưng exception phải có lý do và nên có hạn review.

Chạy sau khi biết CVE làm Trivy fail:

```bash
echo "CVE_ID_THAT_FAILED" >> day2/app/.trivyignore
git add day2/app/.trivyignore
git commit -m "Add temporary Trivy exception"
git push
```

Kết quả mong đợi:

- Nếu CVE đó là nguyên nhân duy nhất làm fail, workflow đi tiếp qua step Trivy.
- Nếu còn CVE critical khác chưa ignore, workflow vẫn fail.

Ý nghĩa:

- Exception không tắt toàn bộ security gate.
- Exception chỉ bỏ qua CVE được chỉ định.

### Test 7: Cosign verify chứng minh image đến từ GitHub Actions

Học được gì:

- Signature không chỉ nói “image đã ký”, mà còn gắn với issuer và identity.
- Với keyless signing, GitHub Actions OIDC là nguồn danh tính.

Sau khi workflow đã push và sign image thành công, copy image digest/tag từ workflow logs rồi chạy local hoặc trên EC2 có cài cosign:

```bash
cosign verify \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
  --certificate-identity-regexp="https://github.com/2hm1901/CDO-Week3/.github/workflows/day2-supply-chain.yml@refs/heads/.*" \
  "ghcr.io/2hm1901/CDO-Week3/day2-demo:IMAGE_TAG"
```

Kết quả mong đợi:

- Verify thành công với image do workflow ký.
- Verify fail nếu issuer/identity regexp không khớp.

Ý nghĩa:

- Bạn kiểm tra được image có nguồn gốc từ workflow của repo, không phải image bị push thủ công từ máy khác.

### Test 8: Admission policy chặn unsigned image

Học được gì:

- CI verify là chưa đủ nếu cluster vẫn cho deploy image chưa ký.
- Admission controller có thể enforce policy ở thời điểm tạo Pod.

Cài Kyverno và policy nếu chưa làm:

```bash
kubectl apply -f https://github.com/kyverno/kyverno/releases/download/v1.12.6/install.yaml
kubectl wait --for=condition=Available deployment/kyverno-admission-controller -n kyverno --timeout=300s
kubectl apply -f day2/manifests/04-kyverno-verify-image-policy.yaml
```

Thử tạo Pod dùng image unsigned từ GHCR:

```bash
kubectl run unsigned-ghcr-test \
  --image=ghcr.io/2hm1901/CDO-Week3/unsigned-demo:latest \
  -n dev
```

Kết quả mong đợi:

- Request bị reject vì image không có Cosign signature hợp lệ.

Thử image không thuộc `ghcr.io/*`:

```bash
kubectl run nginx-not-in-policy-scope \
  --image=nginx:1.27-alpine \
  -n dev
```

Kết quả mong đợi:

- Pod có thể được tạo vì policy hiện chỉ match `ghcr.io/*`.

Ý nghĩa:

- Policy scope rất quan trọng. Bạn phải xác định rõ registry/image nào cần enforce signature.

Cleanup test pod:

```bash
kubectl delete pod unsigned-ghcr-test nginx-not-in-policy-scope -n dev --ignore-not-found
```

## Dọn dẹp

Vì sao cần bước này:

Terraform đã tạo EC2, IAM user/access key và Secrets Manager secret. Nếu không destroy, bạn sẽ tiếp tục tốn chi phí EC2 và giữ lại credentials không cần thiết.

Chạy trên máy local:

```bash
cd day2/terraform
terraform destroy
```
