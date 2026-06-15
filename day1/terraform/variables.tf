variable "aws_region" {
  # Region AWS nơi EC2 lab host sẽ được tạo.
  description = "AWS region used for the EC2 lab host."
  type        = string
  default     = "ap-southeast-2"
}

variable "name_prefix" {
  # Prefix giúp gom tên các resource AWS cùng một lab.
  description = "Prefix for AWS resources."
  type        = string
  default     = "w10-day1-rbac-gatekeeper"
}

variable "instance_type" {
  # Gatekeeper cần nhiều tài nguyên hơn một chút so với cluster kind rỗng.
  description = "EC2 instance type. t3.medium gives enough CPU/RAM for kind + Gatekeeper."
  type        = string
  default     = "t3.medium"
}

variable "allowed_ssh_cidr" {
  # Nên truyền public IP của bạn dạng x.x.x.x/32 khi terraform apply.
  description = "CIDR allowed to SSH into the lab host. Replace the default with your public IP /32 for better security."
  type        = string
  default     = "0.0.0.0/0"
}

variable "kubernetes_version" {
  # Version Kubernetes chạy bên trong kind node.
  description = "Kind node Kubernetes version."
  type        = string
  default     = "v1.30.4"
}

variable "gatekeeper_version" {
  # Version Gatekeeper được cài từ manifest release chính thức.
  description = "OPA Gatekeeper release version installed from the official manifest."
  type        = string
  default     = "v3.17.1"
}
