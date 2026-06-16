output "secret_name" {
  # Dùng giá trị này trong ExternalSecret remoteRef.key.
  description = "AWS Secrets Manager secret name."
  value       = aws_secretsmanager_secret.demo.name
}

output "secret_arn" {
  description = "AWS Secrets Manager secret ARN."
  value       = aws_secretsmanager_secret.demo.arn
}

output "aws_region" {
  description = "AWS region used by SecretStore/ClusterSecretStore."
  value       = var.aws_region
}

output "eso_credentials_script" {
  # Chạy script này trên EC2/minikube để tạo Kubernetes Secret aws-secretsmanager-creds.
  description = "Local script that creates Kubernetes credentials Secret for External Secrets Operator."
  value       = local_sensitive_file.eso_credentials_script.filename
  sensitive   = true
}
