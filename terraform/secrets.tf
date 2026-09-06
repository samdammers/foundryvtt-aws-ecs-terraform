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
#     --region <your-aws-region> \
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

# The Lambda itself never needs this - it only verifies request signatures with the
# (non-secret) public key. This is used solely by scripts/register-discord-commands.sh
# to register slash commands via Discord's REST API, run manually/out-of-band:
#   aws secretsmanager put-secret-value \
#     --secret-id foundry/discord-bot-token \
#     --secret-string "your-bot-token-here" \
#     --region <your-aws-region>
resource "aws_secretsmanager_secret" "discord_bot_token" {
  name        = "foundry/discord-bot-token"
  description = "Discord bot token, populated manually - only used for one-off slash command registration, never by the Lambda"
  tags        = local.tags
}
