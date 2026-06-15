# W10 Day 1 Lab: RBAC + OPA Gatekeeper on AWS

Muc tieu lab:

- Tao namespace `dev`.
- Tao `ServiceAccount` ten `viewer`.
- Tao `Role` chi cho phep `get/list pods`.
- Tao `RoleBinding` gan role cho service account.
- Kiem tra quyen bang `kubectl auth can-i`.
- Cai OPA Gatekeeper.
- Tao `ConstraintTemplate` bat buoc label.
- Tao `Constraint` ap dung policy.
- Thu tao pod thieu label va quan sat bi reject.
- Chuyen policy sang audit/dryrun mode va kiem tra audit result.

## Kien truc

Terraform tao mot EC2 Amazon Linux 2023 trong default VPC. EC2 nay cai Docker, kind, kubectl, tao Kubernetes cluster local, sau do cai Gatekeeper va apply resources lab.

Dung EC2 + kind giup lab nhanh, re, va tap trung vao RBAC/admission policy thay vi ton thoi gian dung EKS.

## Yeu cau truoc khi chay

- AWS credentials da cau hinh tren may local, vi du `aws configure` hoac environment variables.
- Terraform `>= 1.6`.
- Default VPC con ton tai trong region ban chon.

Nen gioi han SSH vao public IP cua ban:

```bash
curl https://checkip.amazonaws.com
```

Dung ket qua do lam `allowed_ssh_cidr`, vi du `1.2.3.4/32`.

## Deploy

```bash
cd day1/terraform
terraform init
terraform apply -var='allowed_ssh_cidr=YOUR_PUBLIC_IP/32'
```

Lay lenh SSH:

```bash
terraform output -raw ssh_command
```

SSH vao EC2:

```bash
ssh -i ./generated/w10-day1-rbac-gatekeeper.pem ec2-user@EC2_PUBLIC_IP
```

Neu cloud-init chua chay xong:

```bash
sudo tail -f /var/log/cloud-init-output.log
```

## Bai lab tren EC2

Doc file huong dan da duoc tao tren EC2:

```bash
less /opt/w10-day1-rbac-gatekeeper/README-on-ec2.md
```

### 1. Kiem tra namespace, service account, role, rolebinding

```bash
kubectl get nodes
kubectl get ns dev
kubectl get sa,role,rolebinding -n dev
```

### 2. Kiem tra RBAC

```bash
kubectl auth can-i get pods -n dev --as=system:serviceaccount:dev:viewer
kubectl auth can-i list pods -n dev --as=system:serviceaccount:dev:viewer
kubectl auth can-i create pods -n dev --as=system:serviceaccount:dev:viewer
kubectl auth can-i delete pods -n dev --as=system:serviceaccount:dev:viewer
kubectl auth can-i list secrets -n dev --as=system:serviceaccount:dev:viewer
```

Ket qua mong doi:

- `get pods`: `yes`
- `list pods`: `yes`
- `create pods`: `no`
- `delete pods`: `no`
- `list secrets`: `no`

Y nghia cot loi: Kubernetes RBAC gan permission theo `verb + resource + namespace`. `viewer` chi xem pod trong namespace `dev`, khong co quyen tao/xoa pod hoac doc secret.

### 3. Kiem tra Gatekeeper deny pod thieu label

```bash
kubectl get pods -n gatekeeper-system
kubectl apply -f /opt/w10-day1-rbac-gatekeeper/manifests/pod-missing-label.yaml
```

Ket qua mong doi: API server reject pod vi thieu label `app`.

Thu pod hop le:

```bash
kubectl apply -f /opt/w10-day1-rbac-gatekeeper/manifests/pod-with-label.yaml
kubectl get pods -n dev --show-labels
```

Y nghia cot loi: Gatekeeper la validating admission webhook. Request tao resource di qua API server, Gatekeeper danh gia Rego policy, va co the deny truoc khi object duoc luu vao etcd.

### 4. Chuyen sang audit/dryrun mode

```bash
kubectl patch k8srequiredlabels dev-pods-must-have-app-label \
  --type merge \
  -p '{"spec":{"enforcementAction":"dryrun"}}'

kubectl apply -f /opt/w10-day1-rbac-gatekeeper/manifests/pod-missing-label.yaml
kubectl get pods -n dev --show-labels
kubectl get k8srequiredlabels dev-pods-must-have-app-label -o yaml
```

Ket qua mong doi: pod thieu label duoc tao, nhung constraint van ghi nhan violation trong status sau khi audit chay.

Y nghia cot loi: enforce mode dung de chan request; dryrun/audit mode dung de do tac dong policy truoc khi bat chan that.

## Cleanup

```bash
cd day1/terraform
terraform destroy
```
