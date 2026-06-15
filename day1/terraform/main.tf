# Lấy AMI Amazon Linux 2023 mới nhất để làm lab host.
# EC2 này chỉ là máy chạy Docker + minikube, không phải Kubernetes managed service.
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

# Chọn một subnet trong default VPC để đặt EC2 public host.
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Sinh SSH key bằng Terraform để không cần tạo key thủ công trong AWS Console.
resource "tls_private_key" "ssh" {
  algorithm = "ED25519"
}

# Ghi private key ra local file. File này bị .gitignore qua thư mục generated/.
resource "local_sensitive_file" "private_key" {
  filename        = "${path.module}/generated/${var.name_prefix}.pem"
  content         = tls_private_key.ssh.private_key_openssh
  file_permission = "0600"
}

# Upload public key lên EC2 Key Pair để bạn SSH vào instance.
resource "aws_key_pair" "lab" {
  key_name   = var.name_prefix
  public_key = tls_private_key.ssh.public_key_openssh
}

# Security group chỉ mở SSH inbound từ CIDR bạn truyền vào.
# Outbound mở toàn bộ để EC2 tải Docker images, kubectl, minikube và Gatekeeper manifest.
resource "aws_security_group" "lab" {
  name        = var.name_prefix
  description = "SSH access for W10 Day 1 RBAC and Gatekeeper lab"
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

# EC2 lab host. Cloud-init user_data sẽ cài công cụ, tạo minikube cluster,
# apply RBAC resources và cài Gatekeeper policy.
resource "aws_instance" "lab" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.lab.id]
  key_name                    = aws_key_pair.lab.key_name
  associate_public_ip_address = true

  root_block_device {
    # 24 GB đủ cho OS, Docker images, minikube profile và manifest lab.
    volume_size = 24
    volume_type = "gp3"
  }

  # templatefile truyền version Kubernetes/Gatekeeper vào bootstrap.sh.
  user_data = templatefile("${path.module}/../scripts/bootstrap.sh", {
    kubernetes_version = var.kubernetes_version
    gatekeeper_version = var.gatekeeper_version
  })

  # Nếu bootstrap script đổi, Terraform sẽ thay EC2 để chạy user_data từ đầu.
  user_data_replace_on_change = true

  tags = {
    Name = var.name_prefix
    Lab  = "w10-day1-rbac-gatekeeper"
  }
}
