variable "aws_region" {
  # Nên dùng cùng region với EC2/minikube của Day 1 để lab dễ theo dõi.
  description = "AWS region where the Secrets Manager secret is created."
  type        = string
  default     = "ap-southeast-2"
}

variable "name_prefix" {
  # Prefix dùng chung cho Secrets Manager secret và IAM user.
  description = "Prefix for AWS resources."
  type        = string
  default     = "w10-day2-secrets-supply-chain"
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
