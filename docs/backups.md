# Backups

EFS world data is backed up via AWS Backup. The backup vault, schedule, and retention are all managed in `terraform/backup.tf`.

## Default schedule

Weekly, with 8 recovery points retained (configurable). The schedule and retention can be adjusted in `backup.tf`:

```hcl
rule {
  rule_name         = "weekly-3am-wednesday"
  target_vault_name = aws_backup_vault.foundry.name
  schedule          = "cron(0 17 ? * TUE *)"  # adjust for your timezone

  lifecycle {
    delete_after = 56  # 8 weekly backups; reduce to save cost
  }
}
```

Run `terraform apply` after any changes to the backup plan.

## Manual one-off backup

Trigger a backup before a version upgrade or any significant change:

```bash
ROLE=$(aws iam get-role \
  --role-name foundry-backup-role \
  --query Role.Arn \
  --output text \
  --region <region>)

JOB=$(aws backup start-backup-job \
  --backup-vault-name foundry-backup \
  --resource-arn <efs-arn> \
  --iam-role-arn $ROLE \
  --region <region> \
  --query BackupJobId \
  --output text)

echo "Job ID: $JOB"
```

Monitor progress:

```bash
aws backup describe-backup-job \
  --backup-job-id $JOB \
  --region <region> \
  --query '{State:State,PercentDone:PercentDone,SizeBytes:BackupSizeInBytes}'
```

Wait for `State: COMPLETED` before proceeding with the upgrade.

## Listing recovery points

```bash
aws backup list-recovery-points-by-vault \
  --backup-vault-name foundry-backup \
  --region <region> \
  --query 'RecoveryPoints[*].{ARN:RecoveryPointArn,Created:CreationDate,SizeGB:BackupSizeInBytes}' \
  --output table
```

## Restoring from backup

AWS Backup restore always creates a **new EFS filesystem** - it does not overwrite the existing one. This means you can restore alongside your current data without risk.

### 1. Start the restore job

```bash
aws backup start-restore-job \
  --recovery-point-arn <recovery-point-arn> \
  --metadata '{"newFileSystem":"true","Encrypted":"true","PerformanceMode":"generalPurpose"}' \
  --iam-role-arn $ROLE \
  --resource-type EFS \
  --region <region>
```

### 2. Wait for completion

```bash
aws backup describe-restore-job \
  --restore-job-id <restore-job-id> \
  --region <region> \
  --query '{Status:Status,CreatedResourceArn:CreatedResourceArn}'
```

Note the `CreatedResourceArn` - this contains the new EFS filesystem ID.

### 3. Point Terraform at the restored filesystem

Update `terraform/efs.tf` to reference the new filesystem ID. The simplest approach is to import the new filesystem into state and update the `creation_token`:

```bash
terraform import aws_efs_file_system.foundry <new-filesystem-id>
```

Then update `creation_token` in `efs.tf` if needed and run `terraform apply`.

### 4. Start the server

```bash
curl https://api.foundry.<domain>/start
```

## What is and isn't backed up

| Data | Backed up? | Where |
|------|-----------|-------|
| World data (scenes, actors, items, journal) | Yes | EFS |
| Installed modules and systems | Yes | EFS |
| Server config (options.json) | Yes | EFS |
| Game assets (maps, tokens, music) | No | S3 - versioning optional |
| Foundry credentials | No | Secrets Manager - not needed, just re-enter |

S3 assets are not included in the EFS backup. If you have assets you can't easily re-upload, consider enabling [S3 versioning](https://docs.aws.amazon.com/AmazonS3/latest/userguide/Versioning.html) on the assets bucket.
