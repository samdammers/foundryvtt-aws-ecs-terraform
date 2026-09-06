# Upgrading FoundryVTT

## Before you start

FoundryVTT world migrations are **one-way and irreversible**. Once a world is opened in a newer version, it cannot be downgraded. Always take a backup before upgrading and verify it completed before proceeding.

## EFS lock file - why you must stop first

FoundryVTT writes a lock file to the EFS data directory when it starts. ECS rolling deployments try to start the new task before stopping the old one - this causes the new container to fail immediately because the lock file is already held.

**Always stop the service completely before applying a new image version.**

## Upgrade path

You must upgrade one major version at a time:

```
V12 -> V13 -> V14
```

Skipping versions (e.g. V12 directly to V14) is not supported - V14's world migration expects V13-format data.

## Step-by-step procedure

### 1. Stop the server

```bash
curl https://api.foundry.<domain>/stop
```

Wait until the task has fully drained (running count reaches 0):

```bash
aws ecs describe-services \
  --cluster foundry \
  --services foundry \
  --region <region> \
  --query 'services[0].runningCount'
```

### 2. Take a backup

```bash
ROLE=$(aws iam get-role --role-name foundry-backup-role --query Role.Arn --output text --region <region>)
JOB=$(aws backup start-backup-job \
  --backup-vault-name foundry-backup \
  --resource-arn <efs-arn> \
  --iam-role-arn $ROLE \
  --region <region> \
  --query BackupJobId --output text)

# Wait for completion
aws backup describe-backup-job --backup-job-id $JOB --region <region> --query '{State:State,SizeBytes:BackupSizeInBytes}'
```

Wait until `State` is `COMPLETED` before continuing.

### 3. Update the image version

Set `TF_VAR_foundry_image` in your `.envrc`:

```bash
export TF_VAR_foundry_image="ghcr.io/felddy/foundryvtt:13"  # or :14
```

Then apply:

```bash
cd terraform/
terraform apply
```

This updates the ECS task definition. Because the service is at desired count 0, no new task starts yet.

### 4. Start the server

```bash
curl https://api.foundry.<domain>/start
```

### 5. Confirm the migration

Open `https://foundry.<domain>` in your browser, confirm the license when prompted, then log in as GM. Foundry will display a migration progress bar - wait for it to complete and verify your world loads correctly.

Check the logs if anything looks wrong:

```bash
aws logs tail /ecs/foundry --follow --region <region>
```

### 6. Proceed to the next version (if applicable)

Once you've confirmed the world is healthy at V13, repeat steps 1-5 to upgrade from V13 to V14. Taking a second backup between steps is recommended.

## Rollback procedure

If a migration fails, restore from the backup taken in step 2. AWS Backup restore creates a **new EFS filesystem** - it does not overwrite the existing one.

```bash
# 1. Find the recovery point ARN
aws backup list-recovery-points-by-vault \
  --backup-vault-name foundry-backup \
  --region <region> \
  --query 'RecoveryPoints[*].{ARN:RecoveryPointArn,Created:CreationDate,Size:BackupSizeInBytes}'

# 2. Start the restore
aws backup start-restore-job \
  --recovery-point-arn <recovery-point-arn> \
  --metadata '{"newFileSystem":"true","Encrypted":"true","PerformanceMode":"generalPurpose"}' \
  --iam-role-arn $ROLE \
  --resource-type EFS \
  --region <region>

# 3. Note the new filesystem ID from the restore job output
aws backup describe-restore-job --restore-job-id <id> --region <region>
```

Once the restore completes:

1. Update `terraform/efs.tf` - replace the `creation_token` and any hardcoded references with the new filesystem ID, or import the new resource
2. Revert `TF_VAR_foundry_image` in your `.envrc` to the previous version
3. Run `terraform apply`
4. Start the server

## Module compatibility

Before upgrading, check that your installed modules are compatible with the new Foundry version. Modules that rely on the automation stack (DAE, midi-qol, and anything that depends on them) are particularly prone to breaking across major versions.

The [FoundryVTT package browser](https://foundryvtt.com/packages/) shows the compatible version range for each module.
