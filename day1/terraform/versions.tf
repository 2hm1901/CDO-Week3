terraform {
  # Khóa phiên bản Terraform tối thiểu để tránh khác biệt cú pháp/provider quá cũ.
  required_version = ">= 1.6.0"

  required_providers {
    # Provider AWS tạo EC2, security group, key pair và đọc thông tin VPC/AMI.
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    # Provider tls sinh SSH private/public key ngay trong Terraform.
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    # Provider local ghi private key ra file .pem trên máy local.
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

provider "aws" {
  # Region được truyền qua biến để dễ đổi khi chạy lab.
  region = var.aws_region
}
