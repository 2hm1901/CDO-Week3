# W10 Day 1 Lab: RBAC + OPA Gatekeeper on AWS

Mục tiêu bài lab:

- Tạo namespace `dev`.
- Tạo `ServiceAccount` tên `viewer`.
- Tạo `Role` chỉ cho phép `get/list pods`.
- Tạo `RoleBinding` gán role cho service account.
- Kiểm tra quyền bằng `kubectl auth can-i`.
- Cài OPA Gatekeeper.
- Tạo `ConstraintTemplate` bắt buộc label.
- Tạo `Constraint` áp dụng policy.
- Thử tạo pod thiếu label và quan sát request bị từ chối.
- Chuyển policy sang audit/dryrun mode và kiểm tra kết quả audit.

## Kiến trúc

Terraform tạo một EC2 Amazon Linux 2023 trong default VPC. EC2 này cài Docker, kind, kubectl, tạo Kubernetes cluster local, sau đó cài Gatekeeper và apply các resource của lab.

Dùng EC2 + kind giúp lab nhanh, rẻ, và tập trung vào RBAC/admission policy thay vì tốn thời gian dựng EKS.

## Yêu cầu trước khi chạy

- AWS credentials đã cấu hình trên máy local, ví dụ `aws configure` hoặc biến môi trường.
- Terraform `>= 1.6`.
- Default VPC còn tồn tại trong region bạn chọn.

Nên giới hạn SSH vào public IP của bạn:

```bash
curl https://checkip.amazonaws.com
```

Dùng kết quả đó làm `allowed_ssh_cidr`, ví dụ `1.2.3.4/32`.

## Triển khai

```bash
cd day1/terraform
terraform init
terraform apply -var='allowed_ssh_cidr=YOUR_PUBLIC_IP/32'
```

Lấy lệnh SSH:

```bash
terraform output -raw ssh_command
```

SSH vào EC2:

```bash
ssh -i ./generated/w10-day1-rbac-gatekeeper.pem ec2-user@EC2_PUBLIC_IP
```

Nếu cloud-init chưa chạy xong:

```bash
sudo tail -f /var/log/cloud-init-output.log
```

Nếu thấy lỗi package conflict hoặc `kubectl: command not found`, nghĩa là bootstrap chưa chạy xong hoặc đã fail. Cách sạch nhất là cập nhật code mới nhất rồi để Terraform thay EC2:

```bash
git pull
cd day1/terraform
terraform apply -replace='aws_instance.lab' -var='allowed_ssh_cidr=YOUR_PUBLIC_IP/32'
```

Sau khi instance mới tạo xong, lấy lại lệnh SSH:

```bash
terraform output -raw ssh_command
```

## Bài lab

Tất cả lệnh trong phần này chạy trên EC2 sau khi SSH vào instance. Bootstrap đã copy manifest vào `/opt/w10-day1-rbac-gatekeeper/manifests`, nên bạn có thể chạy trực tiếp các lệnh bên dưới.

Kiểm tra user và kubeconfig:

```bash
whoami
kubectl config current-context
kubectl get nodes
```

Kết quả mong đợi:

- `whoami`: `ec2-user`
- `kubectl get nodes`: node kind ở trạng thái `Ready`.

### 1. Kiểm tra namespace, service account, role, rolebinding

```bash
kubectl get ns dev
kubectl get sa,role,rolebinding -n dev
kubectl describe role pod-reader -n dev
kubectl describe rolebinding viewer-pod-reader -n dev
```

Kết quả mong đợi:

- Namespace `dev` tồn tại.
- ServiceAccount `viewer` nằm trong namespace `dev`.
- Role `pod-reader` chỉ có verb `get`, `list` trên resource `pods`.
- RoleBinding `viewer-pod-reader` gán Role `pod-reader` cho ServiceAccount `viewer`.

Kiến thức cốt lõi:

- `Role` chỉ có hiệu lực trong một namespace.
- `RoleBinding` nối subject với role. Subject ở lab này là `system:serviceaccount:dev:viewer`.
- Permission trong RBAC được mô tả bằng bộ `apiGroup + resource + verb`.

### 2. Kiểm tra RBAC

```bash
kubectl auth can-i get pods -n dev --as=system:serviceaccount:dev:viewer
kubectl auth can-i list pods -n dev --as=system:serviceaccount:dev:viewer
kubectl auth can-i create pods -n dev --as=system:serviceaccount:dev:viewer
kubectl auth can-i delete pods -n dev --as=system:serviceaccount:dev:viewer
kubectl auth can-i list secrets -n dev --as=system:serviceaccount:dev:viewer
```

Kết quả mong đợi:

- `get pods`: `yes`
- `list pods`: `yes`
- `create pods`: `no`
- `delete pods`: `no`
- `list secrets`: `no`

Ý nghĩa cốt lõi: Kubernetes RBAC gán permission theo `verb + resource + namespace`. `viewer` chỉ xem pod trong namespace `dev`, không có quyền tạo/xóa pod hoặc đọc secret.

Kiểm tra thêm phạm vi namespace:

```bash
kubectl auth can-i get pods -n default --as=system:serviceaccount:dev:viewer
```

Kết quả mong đợi: `no`, vì RoleBinding chỉ nằm trong namespace `dev`.

### 3. Kiểm tra Gatekeeper đã cài đặt

```bash
kubectl get pods -n gatekeeper-system
kubectl get validatingwebhookconfiguration | grep gatekeeper
kubectl get constrainttemplate
kubectl get k8srequiredlabels
```

Kết quả mong đợi:

- Các pod Gatekeeper ở namespace `gatekeeper-system` đang `Running`.
- Có validating webhook của Gatekeeper.
- Có `ConstraintTemplate` tên `k8srequiredlabels`.
- Có constraint `dev-pods-must-have-app-label`.

Kiến thức cốt lõi:

- Gatekeeper hoạt động như validating admission webhook.
- `ConstraintTemplate` định nghĩa loại policy mới bằng Rego.
- `Constraint` là instance của template, chứa scope match và parameter cụ thể.

### 4. Thử pod thiếu label và quan sát bị từ chối

```bash
kubectl apply -f /opt/w10-day1-rbac-gatekeeper/manifests/pod-missing-label.yaml
```

Kết quả mong đợi: API server từ chối pod vì thiếu label `app`. Thông báo lỗi sẽ có nội dung gần như `missing required labels`.

Thử pod hợp lệ:

```bash
kubectl apply -f /opt/w10-day1-rbac-gatekeeper/manifests/pod-with-label.yaml
kubectl get pods -n dev --show-labels
```

Ý nghĩa cốt lõi: Gatekeeper là validating admission webhook. Request tạo resource đi qua API server, Gatekeeper đánh giá Rego policy, và có thể deny trước khi object được lưu vào etcd.

### 5. Chuyển sang audit/dryrun mode

```bash
kubectl patch k8srequiredlabels dev-pods-must-have-app-label \
  --type merge \
  -p '{"spec":{"enforcementAction":"dryrun"}}'

kubectl apply -f /opt/w10-day1-rbac-gatekeeper/manifests/pod-missing-label.yaml
kubectl get pods -n dev --show-labels
kubectl get k8srequiredlabels dev-pods-must-have-app-label -o yaml
```

Kết quả mong đợi: pod thiếu label được tạo, nhưng constraint vẫn ghi nhận violation trong status sau khi audit chạy.

Nếu audit status chưa thấy violation ngay, đợi một lúc rồi chạy lại:

```bash
sleep 60
kubectl get k8srequiredlabels dev-pods-must-have-app-label -o yaml
```

Ý nghĩa cốt lõi: enforce mode dùng để chặn request; dryrun/audit mode dùng để đo tác động policy trước khi bật chặn thật.

### 6. Đưa policy về deny mode nếu muốn thử lại

Xóa pod thiếu label đã được tạo trong dryrun:

```bash
kubectl delete pod missing-label -n dev --ignore-not-found
```

Đưa policy về `deny`:

```bash
kubectl patch k8srequiredlabels dev-pods-must-have-app-label \
  --type merge \
  -p '{"spec":{"enforcementAction":"deny"}}'
```

Thử tạo lại pod thiếu label:

```bash
kubectl apply -f /opt/w10-day1-rbac-gatekeeper/manifests/pod-missing-label.yaml
```

Kết quả mong đợi: pod lại bị từ chối.

## File quan trọng

- `day1/terraform/main.tf`: tạo EC2, security group, key pair.
- `day1/terraform/variables.tf`: region, instance type, SSH CIDR, Kubernetes/Gatekeeper version.
- `day1/scripts/bootstrap.sh`: cài Docker/kind/kubectl, tạo cluster, apply RBAC và Gatekeeper.
- `day1/manifests/01-rbac.yaml`: namespace, service account, role, rolebinding.
- `day1/manifests/02-required-label-template.yaml`: Gatekeeper `ConstraintTemplate`.
- `day1/manifests/03-required-label-constraint.yaml`: Gatekeeper `Constraint`.
- `day1/manifests/pod-missing-label.yaml`: pod dùng để test reject.
- `day1/manifests/pod-with-label.yaml`: pod hợp lệ dùng để test admit.

## Dọn dẹp

Chạy trên máy local, không phải trên EC2:

```bash
cd day1/terraform
terraform destroy
```
