variable "aws_region" {
  # Region AWS nơi EC2 lab host và Secrets Manager secret sẽ được tạo.
  description = "AWS region where the Secrets Manager secret is created."
  type        = string
  default     = "ap-southeast-2"
}

variable "name_prefix" {
  # Prefix dùng chung cho EC2, Secrets Manager secret và IAM user.
  description = "Prefix for AWS resources."
  type        = string
  default     = "w10-day2-secrets-supply-chain"
}

variable "instance_type" {
  # Minikube + ESO + optional Kyverno cần nhiều tài nguyên hơn cluster rỗng.
  description = "EC2 instance type for the Day 2 minikube lab host."
  type        = string
  default     = "t3.medium"
}

variable "allowed_ssh_cidr" {
  # Nên truyền public IP của bạn dạng x.x.x.x/32 khi terraform apply.
  description = "CIDR allowed to SSH into the lab host."
  type        = string
  default     = "0.0.0.0/0"
}

variable "kubernetes_version" {
  # Version Kubernetes chạy bên trong minikube cluster.
  description = "Minikube Kubernetes version."
  type        = string
  default     = "v1.30.4"
}

variable "secret_name" {
  # Đây là key mà ExternalSecret sẽ đọc từ AWS Secrets Manager.
  description = "AWS Secrets Manager secret name read by External Secrets Operator."
  type        = string
  default     = "w10/day2/demo-app"
}

variable "secret_payload" {
  # Payload demo để ESO sync thành Kubernetes Secret app-config.
  description = "Demo JSON payload stored in AWS Secrets Manager."
  type = object({
    username = string
    password = string
    api_key  = string
  })
  sensitive = true
  default = {
    username = "demo-user"
    password = "change-me-in-real-life"
    api_key  = "demo-api-key"
  }
}
