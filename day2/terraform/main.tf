# Lấy AMI Amazon Linux 2023 mới nhất để chạy Docker + minikube.
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Dùng default VPC để lab ít cấu hình mạng nhất có thể.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Sinh SSH key riêng cho Day 2 để lab độc lập với Day 1.
resource "tls_private_key" "ssh" {
  algorithm = "ED25519"
}

resource "local_sensitive_file" "private_key" {
  filename        = "${path.module}/generated/${var.name_prefix}.pem"
  content         = tls_private_key.ssh.private_key_openssh
  file_permission = "0600"
}

resource "aws_key_pair" "lab" {
  key_name   = var.name_prefix
  public_key = tls_private_key.ssh.public_key_openssh
}

resource "aws_security_group" "lab" {
  name        = var.name_prefix
  description = "SSH access for W10 Day 2 Secrets and Supply Chain lab"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = var.name_prefix
  }
}

# EC2 lab host độc lập cho Day 2. user_data cài Docker, kubectl, minikube
# và clone repo để bạn có sẵn manifest/workflow mẫu trên máy lab.
resource "aws_instance" "lab" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.lab.id]
  key_name                    = aws_key_pair.lab.key_name
  associate_public_ip_address = true

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  user_data = templatefile("${path.module}/../scripts/bootstrap.sh", {
    kubernetes_version = var.kubernetes_version
  })

  user_data_replace_on_change = true

  tags = {
    Name = var.name_prefix
    Lab  = "w10-day2-secrets-supply-chain"
  }
}

# Tạo secret thật trong AWS Secrets Manager.
# External Secrets Operator sẽ đọc secret này rồi sync vào Kubernetes Secret.
resource "aws_secretsmanager_secret" "demo" {
  name        = var.secret_name
  description = "W10 Day 2 demo secret synced to Kubernetes by External Secrets Operator"

  tags = {
    Name = var.name_prefix
    Lab  = "w10-day2-secrets-supply-chain"
  }
}

# Ghi version đầu tiên của secret dưới dạng JSON.
# Trong môi trường thật, không nên hardcode secret trong Terraform default.
resource "aws_secretsmanager_secret_version" "demo" {
  secret_id     = aws_secretsmanager_secret.demo.id
  secret_string = jsonencode(var.secret_payload)
}

# IAM user tối thiểu cho lab minikube.
# Trên EKS production nên dùng IRSA/Pod Identity thay vì access key tĩnh.
resource "aws_iam_user" "eso" {
  name = "${var.name_prefix}-eso"

  tags = {
    Name = "${var.name_prefix}-eso"
    Lab  = "w10-day2-secrets-supply-chain"
  }
}

# Access key này sẽ được đưa vào Kubernetes Secret để ESO gọi AWS Secrets Manager.
resource "aws_iam_access_key" "eso" {
  user = aws_iam_user.eso.name
}

# Policy chỉ cho phép đọc đúng secret của lab, không cấp quyền rộng.
data "aws_iam_policy_document" "eso_read_secret" {
  statement {
    sid    = "ReadOnlySpecificSecret"
    effect = "Allow"

    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret"
    ]

    resources = [
      aws_secretsmanager_secret.demo.arn
    ]
  }
}

resource "aws_iam_user_policy" "eso_read_secret" {
  name   = "${var.name_prefix}-read-secret"
  user   = aws_iam_user.eso.name
  policy = data.aws_iam_policy_document.eso_read_secret.json
}

# Ghi sẵn lệnh kubectl tạo Secret chứa AWS credentials cho ESO.
# File này nằm trong generated/ và bị .gitignore, vì có secret access key.
resource "local_sensitive_file" "eso_credentials_script" {
  filename        = "${path.module}/generated/create-eso-aws-credentials.sh"
  file_permission = "0700"
  content = templatefile("${path.module}/templates/create-eso-aws-credentials.sh.tftpl", {
    access_key_id     = aws_iam_access_key.eso.id
    secret_access_key = aws_iam_access_key.eso.secret
  })
}
