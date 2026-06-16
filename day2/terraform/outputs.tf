output "instance_public_ip" {
  # IP public của EC2 lab host Day 2.
  description = "Public IP of the Day 2 EC2 lab host."
  value       = aws_instance.lab.public_ip
}

output "ssh_private_key_path" {
  description = "Local SSH private key generated for the Day 2 lab host."
  value       = local_sensitive_file.private_key.filename
  sensitive   = true
}

output "ssh_command" {
  description = "SSH command for the Day 2 lab host."
  value       = "ssh -i ${local_sensitive_file.private_key.filename} ec2-user@${aws_instance.lab.public_ip}"
  sensitive   = true
}

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
  # Copy script này lên EC2/minikube để tạo Kubernetes Secret aws-secretsmanager-creds.
  description = "Local script that creates Kubernetes credentials Secret for External Secrets Operator."
  value       = local_sensitive_file.eso_credentials_script.filename
  sensitive   = true
}

output "scp_credentials_command" {
  description = "Command that copies the ESO AWS credentials script to the Day 2 EC2 lab host."
  value       = "scp -i ${local_sensitive_file.private_key.filename} ${local_sensitive_file.eso_credentials_script.filename} ec2-user@${aws_instance.lab.public_ip}:/home/ec2-user/create-eso-aws-credentials.sh"
  sensitive   = true
}

output "bootstrap_log_command" {
  description = "Use this after SSH to watch cloud-init bootstrap status."
  value       = "sudo tail -f /var/log/cloud-init-output.log"
}
