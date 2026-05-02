# Operations

Day-to-day management of your FoundryVTT server.

## Starting and stopping

The management API is the preferred way to start and stop the server. It scales the ECS service desired count between 0 (stopped) and 1 (running).

```bash
# Start
curl https://api.foundry.<domain>/start

# Stop
curl https://api.foundry.<domain>/stop
```

These are plain GET requests — you can bookmark them in your browser or share the links with players to let them start the server themselves.

Alternatively, via the AWS CLI:

```bash
# Start
aws ecs update-service --cluster foundry --service foundry --desired-count 1 --region <region>

# Stop
aws ecs update-service --cluster foundry --service foundry --desired-count 0 --region <region>
```

> **Note:** `terraform apply` will never reset the desired count — the ECS service has `lifecycle { ignore_changes = [desired_count] }`. Terraform only manages the task definition and service configuration, not whether the server is running.

## Auto-stop schedule

The server stops automatically on the schedule defined by `auto_stop_schedule` in your `terraform.tfvars` (default: 3pm UTC daily). This prevents the Fargate task running overnight and accumulating cost if you forget to stop it.

To change the schedule, update `auto_stop_schedule` and run `terraform apply`:

```hcl
# Examples
auto_stop_schedule = "cron(0 13 * * ? *)"   # 1pm UTC daily
auto_stop_schedule = "cron(0 11 ? * MON *)" # 9pm AEST Monday only
```

The schedule uses [EventBridge cron syntax](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-scheduled-rule-pattern.html) in UTC.

## First start after deployment

On the very first start (or after a new task definition is deployed), FoundryVTT will ask you to verify your software license. This is expected — it happens because the container hostname changes between task restarts.

1. Open `https://foundry.<domain>` in your browser
2. You'll be prompted to confirm the license — click through
3. Log in with your admin password
4. Your world will load

This confirmation is required on every container restart. It's a known limitation of running FoundryVTT in a containerised environment — see [Known limitations](../README.md#known-limitations).

## Managing S3 asset access

Large game assets (maps, tokens, music) are stored in S3 and served directly to player browsers. Access is controlled by an IP allowlist in the S3 bucket policy, so only known IPs can retrieve assets.

At the start of each session, players need their IP added to the allowlist:

```bash
# Each player visits this URL from their browser (or you call it for them)
curl https://api.foundry.<domain>/ip/add
```

At the end of a session, reset the allowlist back to VPC CIDRs only:

```bash
curl https://api.foundry.<domain>/ip/reset
```

The reset is also run automatically on the same schedule as the auto-stop, so stale IPs are cleared daily.

### Why IP allowlisting instead of public access?

S3 objects don't require authentication when accessed via a browser — if the bucket were fully public anyone with a direct URL could download your maps and assets. The IP allowlist provides a lightweight barrier without requiring players to authenticate.

## Checking service status

```bash
# Is the task running?
aws ecs describe-services \
  --cluster foundry \
  --services foundry \
  --region <region> \
  --query 'services[0].{desired:desiredCount,running:runningCount,status:status}'

# Which task definition is active?
aws ecs describe-services \
  --cluster foundry \
  --services foundry \
  --region <region> \
  --query 'services[0].taskDefinition'
```
