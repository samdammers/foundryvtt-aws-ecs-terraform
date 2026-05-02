resource "aws_iam_role" "backup" {
  name = "foundry-backup-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "backup.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_backup_vault" "foundry" {
  name = "foundry-backup"
  tags = local.tags
}

resource "aws_backup_plan" "foundry" {
  name = "foundry-weekly"

  rule {
    rule_name         = "weekly-3am-aest-wednesday"
    target_vault_name = aws_backup_vault.foundry.name
    schedule          = "cron(0 17 ? * TUE *)" # 3am AEST Wednesday = 17:00 UTC Tuesday

    lifecycle {
      delete_after = 56 # 8 weekly backups
    }
  }

  tags = local.tags
}

resource "aws_backup_selection" "foundry" {
  name         = "foundry-efs"
  plan_id      = aws_backup_plan.foundry.id
  iam_role_arn = aws_iam_role.backup.arn

  resources = [aws_efs_file_system.foundry.arn]
}
