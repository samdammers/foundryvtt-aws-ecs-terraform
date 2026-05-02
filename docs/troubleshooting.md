# Troubleshooting

## Viewing logs

Stream live container logs:

```bash
aws logs tail /ecs/foundry --follow --region <region>
```

Fetch logs from a specific time window:

```bash
aws logs tail /ecs/foundry --since 1h --region <region>
```

## Shell into the running container

Requires the [AWS Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) installed locally. ECS Exec is enabled on the service by default in this Terraform config.

```bash
TASK=$(aws ecs list-tasks \
  --cluster foundry \
  --service-name foundry \
  --query 'taskArns[0]' \
  --output text \
  --region <region>)

aws ecs execute-command \
  --cluster foundry \
  --task $TASK \
  --container foundry \
  --interactive \
  --command /bin/sh \
  --region <region>
```

Once inside the container, world data is at `/data/Data/`, modules at `/data/Data/modules/`, and logs from previous runs at `/data/logs/`.

## Common issues

### License verification prompt on every start

**Symptom:** Every time you start the server you're asked to confirm the software license before the world loads.

**Cause:** ECS Fargate assigns a new random container hostname on each task start. FoundryVTT ties its license verification to the machine hostname, so it sees a different host each time.

**Workaround:** This is a known limitation with containerised Foundry deployments. Confirm the license through the browser UI — it takes about 30 seconds. There is no permanent fix short of injecting `FOUNDRY_LICENSE_KEY` as an environment variable (which automates the verification step but requires storing your license key in Secrets Manager).

### Container exits immediately after starting

**Symptom:** The ECS task reaches RUNNING briefly then stops. The service shows 0 running tasks.

**Steps to diagnose:**

1. Check the stopped task's exit code and reason:
```bash
aws ecs describe-tasks \
  --cluster foundry \
  --tasks <task-id> \
  --region <region> \
  --query 'tasks[0].{stopReason:stoppedReason,exitCode:containers[0].exitCode}'
```

2. Check the container logs for the failed task:
```bash
aws logs get-log-events \
  --log-group-name /ecs/foundry \
  --log-stream-name "foundry/foundry/<task-id>" \
  --region <region> \
  --query 'events[*].message' \
  --output text
```

**Common causes:**
- `EFS lock file` error — another task is still running or didn't shut down cleanly. Stop the service, wait for running count to reach 0, then start again.
- `Cannot find module` or Node.js error — the container command was overridden incorrectly. Check that `command` in the task definition is not set.
- Secrets Manager error — the Foundry credentials secret is missing or malformed. Verify with `aws secretsmanager get-secret-value --secret-id foundry/credentials --region <region>`.
- `Incorrect username or password` in logs — the credentials in Secrets Manager don't match your FoundryVTT account.

### Assets not loading for players (403 or blocked)

**Symptom:** Players can connect to Foundry but maps, tokens, or audio fail to load. Browser console shows 403 errors from S3.

**Cause:** The player's IP is not in the S3 bucket policy allowlist.

**Fix:** Have each affected player visit:
```
https://api.foundry.<domain>/ip/add
```

Or call it yourself from their location. After adding, Foundry may need a browser refresh to retry the asset requests.

### World fails to load after upgrade

**Symptom:** After a version upgrade the world either won't open or shows errors during migration.

**Steps:**
1. Check the logs for migration errors: `aws logs tail /ecs/foundry --since 30m --region <region>`
2. Stop the server immediately to prevent further data changes
3. Restore from the pre-upgrade backup — see [backups.md](backups.md)
4. Verify you haven't skipped a major version — upgrades must go one version at a time (V12 → V13 → V14)

### ECS task stuck in PENDING

**Symptom:** The task stays in PENDING state and never reaches RUNNING.

**Common causes:**
- **Fargate capacity** — ARM64 capacity can be constrained in some regions. Change `cpu_architecture` to `X86_64` in `ecs.tf` and run `terraform apply`.
- **EFS mount failure** — the EFS mount targets may not be ready or the security group isn't allowing NFS traffic. Check that the EFS security group allows port 2049 from the ECS task security group.
- **ECR/image pull failure** — the `ghcr.io` image pull failed. Check that the task has outbound internet access (the task uses `assign_public_ip = true` for this).

### Terraform apply fails with "error modifying ECS Service"

If you see this when running `terraform apply` while the service is running, it's usually because `force_new_deployment = true` triggered a rolling deploy that conflicts with the EFS lock. Stop the service first, then apply.
