resource "aws_secretsmanager_secret" "foundry" {
  name                    = "foundry/credentials"
  description             = "FoundryVTT username, password, and admin key"
  recovery_window_in_days = 7

  tags = local.tags
}

# Placeholder values written on first apply.
# After apply, set real values:
#   aws secretsmanager put-secret-value \
#     --secret-id foundry/credentials \
#     --region ap-southeast-4 \
#     --secret-string '{"username":"<email>","password":"<pass>","admin_key":"<key>"}'
resource "aws_secretsmanager_secret_version" "foundry_placeholder" {
  secret_id = aws_secretsmanager_secret.foundry.id
  secret_string = jsonencode({
    username  = "PLACEHOLDER"
    password  = "PLACEHOLDER"
    admin_key = "PLACEHOLDER"
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}
