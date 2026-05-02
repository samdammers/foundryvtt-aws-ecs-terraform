# FoundryVTT on AWS — Terraform

![FoundryVTT on AWS ECS Terraform](docs/FoundryVTT_AWS_ECS_Terraform.png)

Terraform infrastructure for running [FoundryVTT](https://foundryvtt.com/) on AWS ECS Fargate. Built for a personal game server running a small group — cheap to operate, easy to start/stop between sessions, with persistent world data on EFS.

## Architecture

```
Route53 (foundry.example.com)
  → ALB (HTTPS/443, 1h idle timeout for WebSocket)
    → ECS Fargate task (ghcr.io/felddy/foundryvtt:14, ARM64)
      → EFS /data  (worlds, config, modules)
      → S3         (game assets — maps, tokens, audio)
        ↑ VPC Gateway Endpoint (no NAT needed)

Route53 (api.foundry.example.com)
  → API Gateway REST
    → Lambda
        GET /start     — scale ECS to 1
        GET /stop      — scale ECS to 0
        GET /ip/add    — add your current IP to S3 asset allowlist
        GET /ip/reset  — reset S3 allowlist to VPC CIDRs only
```

**Key design decisions:**
- Fargate ARM64 — better price/performance, available in most regions
- EFS for world data — survives task restarts and replacements without any manual steps
- S3 for large assets — cheaper than EFS, served directly to player browsers via IP allowlist
- Scale-to-zero — stop the task between sessions to minimise cost; EFS data persists
- No NAT gateway — Fargate tasks use public IPs + S3 VPC Gateway endpoint to keep egress free

## Cost estimate

At roughly 8 hours/week of play:

| Resource | ~Monthly cost |
|----------|--------------|
| ECS Fargate (1 vCPU / 2 GB, ARM64) | ~$3–5 |
| EFS Standard | ~$0.30/GB |
| ALB | ~$20 (fixed + LCU) |
| API Gateway + Lambda | < $1 |
| S3 assets | < $1 |
| **Total** | **~$25–30/month** |

The ALB is the dominant cost. If you want to go cheaper, replacing it with an NLB or using Cloudflare in front of a direct Fargate IP are options, but the ALB gives you managed TLS, health checks, and WebSocket support out of the box.

## Prerequisites

- AWS account with a Route53 hosted zone for your domain
- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5
- [AWS CLI](https://aws.amazon.com/cli/) configured (`aws configure`)
- A FoundryVTT license (required by the [felddy/foundryvtt](https://github.com/felddy/foundryvtt-docker) container to download the software)
- An S3 bucket for Terraform state (or use a local backend)

## Setup

### 1. Create an ACM certificate for the API subdomain

```bash
aws acm request-certificate \
  --domain-name api.foundry.example.com \
  --validation-method DNS \
  --region ap-southeast-2
```

Validate it via DNS (add the CNAME record Route53 shows you), then copy the certificate ARN.

### 2. Configure variables

```bash
cd terraform/
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values
```

### 3. Configure the backend

Edit `backend.tf` to point at your Terraform state S3 bucket, then:

```bash
terraform init
```

### 4. Deploy

```bash
terraform plan
terraform apply
```

### 5. Set Foundry credentials

After the first apply, populate the Secrets Manager secret with your FoundryVTT credentials:

```bash
aws secretsmanager put-secret-value \
  --secret-id foundry/credentials \
  --secret-string '{"username":"your@email.com","password":"yourpassword","admin_key":"youradminkey"}' \
  --region ap-southeast-2
```

### 6. Copy world data to EFS

If you have an existing world, mount the EFS and copy your data across before starting the container. The easiest way is via an EC2 instance in the same VPC:

```bash
sudo mount -t nfs4 <efs-dns-name>:/ /mnt/efs
sudo cp -r /path/to/your/worlds/ /mnt/efs/foundrydata/Data/worlds/
```

### 7. Start the server

```bash
curl https://api.foundry.example.com/start
```

Then open `https://foundry.example.com`, confirm the software license, and your world will load.

## Starting and stopping

```bash
# Start
curl https://api.foundry.example.com/start

# Stop
curl https://api.foundry.example.com/stop
```

The server auto-stops daily on the schedule defined by `auto_stop_schedule` (default: 3pm UTC). Adjust this for your timezone in `terraform.tfvars`.

## Managing S3 asset access

FoundryVTT serves large assets (maps, tokens, music) directly from S3 to player browsers. Access is controlled by an IP allowlist in the bucket policy.

```bash
# Add your current IP
curl https://api.foundry.example.com/ip/add

# Reset to VPC CIDRs only (removes all player IPs)
curl https://api.foundry.example.com/ip/reset
```

Call `/ip/add` from each player's browser at the start of a session so their IPs can reach the S3 assets.

## Backups

EFS is backed up weekly via AWS Backup (configurable in `backup.tf`). To trigger a manual backup before a version upgrade:

```bash
ROLE=$(aws iam get-role --role-name foundry-backup-role --query Role.Arn --output text --region <region>)
aws backup start-backup-job \
  --backup-vault-name foundry-backup \
  --resource-arn <efs-arn> \
  --iam-role-arn $ROLE \
  --region <region>
```

## Upgrading FoundryVTT

World migrations are one-way and irreversible. Always take a backup first, stop the service, then upgrade one major version at a time (V12 → V13 → V14).

```bash
# 1. Stop
curl https://api.foundry.example.com/stop

# 2. Take a backup (see above)

# 3. Update foundry_image in terraform.tfvars, then apply
terraform apply

# 4. Start and confirm the world migrates successfully
curl https://api.foundry.example.com/start
```

## Debugging

```bash
# Container logs
aws logs tail /ecs/foundry --follow --region <region>

# Shell into the running container (requires Session Manager plugin)
TASK=$(aws ecs list-tasks --cluster foundry --service-name foundry --query 'taskArns[0]' --output text --region <region>)
aws ecs execute-command --cluster foundry --task $TASK --container foundry --interactive --command /bin/sh --region <region>
```

## Known limitations

- **License re-verification on restart** — ECS Fargate assigns a new container hostname on each task start, which triggers Foundry's license check. You'll need to click through the confirmation in the admin UI after each start. This is a Foundry limitation with containerised deployments.
- **ARM64 only** — if you hit Fargate capacity errors in your region, change `cpu_architecture` to `X86_64` in `ecs.tf`.
- **ALB cost** — the ALB runs continuously even when the ECS task is stopped. It's the biggest fixed cost in this setup.

## File structure

```
terraform/
├── acm.tf              # ACM certificate for foundry.example.com
├── alb.tf              # Application load balancer + HTTPS listener
├── apigateway.tf       # REST API — /start /stop /ip/add /ip/reset
├── backup.tf           # AWS Backup vault + weekly schedule
├── backend.tf          # S3 remote state (update before init)
├── data.tf             # Data sources (VPC, Route53 zone)
├── dns.tf              # Route53 records
├── ecs.tf              # ECS cluster, task definition, service
├── efs.tf              # EFS filesystem, mount targets, access point
├── iam.tf              # IAM roles for ECS, Lambda, Backup
├── lambda.tf           # Lambda function + EventBridge triggers
├── lambda/
│   └── manager.py      # Lambda handler
├── locals.tf           # Shared locals (FQDNs, port, tags)
├── outputs.tf          # Useful outputs after apply
├── providers.tf        # AWS provider
├── s3.tf               # S3 bucket + IP-restricted bucket policy
├── secrets.tf          # Secrets Manager for Foundry credentials
├── security_groups.tf  # SGs for ALB, ECS task, EFS
├── variables.tf        # All input variables
├── terraform.tfvars.example  # Copy to terraform.tfvars and fill in
└── vpc_endpoint.tf     # S3 Gateway endpoint (required for Fargate → S3)
```

## Attribution

This project relies on the following open source work:

- **[felddy/foundryvtt-docker](https://github.com/felddy/foundryvtt-docker)** by [Shane Engelman](https://github.com/felddy) and [contributors](https://github.com/felddy/foundryvtt-docker/graphs/contributors) — the container image that handles downloading, installing, and running FoundryVTT. Licensed under MIT. This project would not exist without it.

- **[FoundryVTT](https://foundryvtt.com/)** — the virtual tabletop software itself. FoundryVTT is proprietary software; a valid license is required to use it.

## AI assistance

This infrastructure was developed with the assistance of AI tools. The architecture decisions, configuration, and code were authored and reviewed by a human; AI was used to accelerate research, drafting, and iteration.

## License

[MIT](LICENSE) — you're free to use, modify, and distribute this as you see fit. Attribution appreciated but not required.
