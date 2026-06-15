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

## Bai lab

Tat ca lenh trong phan nay chay tren EC2 sau khi SSH vao instance. Bootstrap da copy manifest vao `/opt/w10-day1-rbac-gatekeeper/manifests`, nen ban co the chay truc tiep cac lenh ben duoi.

Kiem tra user va kubeconfig:

```bash
whoami
kubectl config current-context
kubectl get nodes
```

Ket qua mong doi:

- `whoami`: `ec2-user`
- `kubectl get nodes`: node kind o trang thai `Ready`

### 1. Kiem tra namespace, service account, role, rolebinding

```bash
kubectl get ns dev
kubectl get sa,role,rolebinding -n dev
kubectl describe role pod-reader -n dev
kubectl describe rolebinding viewer-pod-reader -n dev
```

Ket qua mong doi:

- Namespace `dev` ton tai.
- ServiceAccount `viewer` nam trong namespace `dev`.
- Role `pod-reader` chi co verbs `get`, `list` tren resource `pods`.
- RoleBinding `viewer-pod-reader` gan Role `pod-reader` cho ServiceAccount `viewer`.

Kien thuc cot loi:

- `Role` chi co hieu luc trong mot namespace.
- `RoleBinding` noi subject voi role. Subject o lab nay la `system:serviceaccount:dev:viewer`.
- Permission trong RBAC duoc mo ta bang bo `apiGroup + resource + verb`.

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

Kiem tra them scope namespace:

```bash
kubectl auth can-i get pods -n default --as=system:serviceaccount:dev:viewer
```

Ket qua mong doi: `no`, vi RoleBinding chi nam trong namespace `dev`.

### 3. Kiem tra Gatekeeper da cai dat

```bash
kubectl get pods -n gatekeeper-system
kubectl get validatingwebhookconfiguration | grep gatekeeper
kubectl get constrainttemplate
kubectl get k8srequiredlabels
```

Ket qua mong doi:

- Cac pod Gatekeeper o namespace `gatekeeper-system` dang `Running`.
- Co validating webhook cua Gatekeeper.
- Co `ConstraintTemplate` ten `k8srequiredlabels`.
- Co constraint `dev-pods-must-have-app-label`.

Kien thuc cot loi:

- Gatekeeper hoat dong nhu validating admission webhook.
- `ConstraintTemplate` dinh nghia loai policy moi bang Rego.
- `Constraint` la instance cua template, chua scope match va parameter cu the.

### 4. Thu pod thieu label va quan sat bi reject

```bash
kubectl apply -f /opt/w10-day1-rbac-gatekeeper/manifests/pod-missing-label.yaml
```

Ket qua mong doi: API server reject pod vi thieu label `app`. Thong bao loi se co noi dung gan nhu `missing required labels`.

Thu pod hop le:

```bash
kubectl apply -f /opt/w10-day1-rbac-gatekeeper/manifests/pod-with-label.yaml
kubectl get pods -n dev --show-labels
```

Y nghia cot loi: Gatekeeper la validating admission webhook. Request tao resource di qua API server, Gatekeeper danh gia Rego policy, va co the deny truoc khi object duoc luu vao etcd.

### 5. Chuyen sang audit/dryrun mode

```bash
kubectl patch k8srequiredlabels dev-pods-must-have-app-label \
  --type merge \
  -p '{"spec":{"enforcementAction":"dryrun"}}'

kubectl apply -f /opt/w10-day1-rbac-gatekeeper/manifests/pod-missing-label.yaml
kubectl get pods -n dev --show-labels
kubectl get k8srequiredlabels dev-pods-must-have-app-label -o yaml
```

Ket qua mong doi: pod thieu label duoc tao, nhung constraint van ghi nhan violation trong status sau khi audit chay.

Neu audit status chua thay violation ngay, doi mot luc roi chay lai:

```bash
sleep 60
kubectl get k8srequiredlabels dev-pods-must-have-app-label -o yaml
```

Y nghia cot loi: enforce mode dung de chan request; dryrun/audit mode dung de do tac dong policy truoc khi bat chan that.

### 6. Dua policy ve deny mode neu muon thu lai

Xoa pod thieu label da duoc tao trong dryrun:

```bash
kubectl delete pod missing-label -n dev --ignore-not-found
```

Dua policy ve `deny`:

```bash
kubectl patch k8srequiredlabels dev-pods-must-have-app-label \
  --type merge \
  -p '{"spec":{"enforcementAction":"deny"}}'
```

Thu tao lai pod thieu label:

```bash
kubectl apply -f /opt/w10-day1-rbac-gatekeeper/manifests/pod-missing-label.yaml
```

Ket qua mong doi: pod lai bi reject.

## File quan trong

- `day1/terraform/main.tf`: tao EC2, security group, key pair.
- `day1/terraform/variables.tf`: region, instance type, SSH CIDR, Kubernetes/Gatekeeper version.
- `day1/scripts/bootstrap.sh`: cai Docker/kind/kubectl, tao cluster, apply RBAC va Gatekeeper.
- `day1/manifests/01-rbac.yaml`: namespace, service account, role, rolebinding.
- `day1/manifests/02-required-label-template.yaml`: Gatekeeper `ConstraintTemplate`.
- `day1/manifests/03-required-label-constraint.yaml`: Gatekeeper `Constraint`.
- `day1/manifests/pod-missing-label.yaml`: pod dung de test reject.
- `day1/manifests/pod-with-label.yaml`: pod hop le dung de test admit.

## Cleanup

Chay tren may local, khong phai tren EC2:

```bash
cd day1/terraform
terraform destroy
```
