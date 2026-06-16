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
