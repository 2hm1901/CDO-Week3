variable "aws_region" {
  description = "AWS region used for the EC2 lab host."
  type        = string
  default     = "ap-southeast-1"
}

variable "name_prefix" {
  description = "Prefix for AWS resources."
  type        = string
  default     = "w10-day1-rbac-gatekeeper"
}

variable "instance_type" {
  description = "EC2 instance type. t3.medium gives enough CPU/RAM for kind + Gatekeeper."
  type        = string
  default     = "t3.medium"
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed to SSH into the lab host. Replace the default with your public IP /32 for better security."
  type        = string
  default     = "0.0.0.0/0"
}

variable "kubernetes_version" {
  description = "Kind node Kubernetes version."
  type        = string
  default     = "v1.30.4"
}

variable "gatekeeper_version" {
  description = "OPA Gatekeeper release version installed from the official manifest."
  type        = string
  default     = "v3.17.1"
}
