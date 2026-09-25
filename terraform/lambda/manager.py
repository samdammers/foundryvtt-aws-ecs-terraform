"""
FoundryVTT management Lambda.

Routes:
  GET  /start      - Scale ECS Foundry service to 1 task
  GET  /stop       - Scale ECS Foundry service to 0 tasks
  GET  /status     - ECS service status (desired/running count, no credentials)
  GET  /ip/add     - Add caller IP to S3 bucket policy allowlist
  GET  /ip/reset   - Reset S3 bucket policy to VPC CIDRs only
  POST /discord    - Discord Interactions Endpoint (slash commands: /foundry-start,
                     /foundry-stop, /foundry-status). Authenticated by Discord's
                     Ed25519 request signature, not AWS auth - Discord's servers call
                     this directly and there's no IP to allowlist. Uses Discord Deferred
                     Responses (type 5) with asynchronous background processing to
                     reliably respond in <100ms and avoid Discord's 3-second timeout.
Scheduled event    - Triggers /ip/reset daily at 1am AEST
Scheduled event    - Stops ECS service on auto_stop schedule (scheduled_action=ecs_stop)
Async event        - {"async_action": "discord_command"}: asynchronous execution of
                     slash commands invoked by the synchronous /discord router.
ECS task event     - Updates origin Route53 A record when ECS task reaches RUNNING
                     state (only fires when use_cloudfront = true - see lambda.tf)
"""
import base64
import json
import os
import urllib.error
import urllib.request

import boto3
import nacl.exceptions
import nacl.signing

BUCKET_NAME = os.environ["S3_BUCKET"]
ECS_CLUSTER = os.environ.get("ECS_CLUSTER", "foundry")
ECS_SERVICE = os.environ.get("ECS_SERVICE", "foundry")
HOSTED_ZONE_ID = os.environ.get("HOSTED_ZONE_ID", "")
ORIGIN_RECORD = os.environ.get("ORIGIN_RECORD", "")
DISCORD_PUBLIC_KEY = os.environ.get("DISCORD_PUBLIC_KEY", "")
DISCORD_WEBHOOK_URL = os.environ.get("DISCORD_WEBHOOK_URL", "")
FOUNDRY_URL = os.environ.get("FOUNDRY_URL", "")
IP_ADD_URL = os.environ.get("IP_ADD_URL", "")

DISCORD_EPHEMERAL_FLAG = 64  # only the command's caller sees the response

# Module-level client caches (reused across warm invocations)
_CACHED_SESSION = None
_CACHED_ECS = None
_CACHED_S3 = None
_CACHED_ROUTE53 = None
_CACHED_EC2 = None
_CACHED_LAMBDA = None


def get_session():
    global _CACHED_SESSION
    if _CACHED_SESSION is None:
        _CACHED_SESSION = boto3.session.Session()
    return _CACHED_SESSION


def get_ecs_client():
    global _CACHED_ECS
    if _CACHED_ECS is None:
        _CACHED_ECS = get_session().client("ecs")
    return _CACHED_ECS


def get_s3_client():
    global _CACHED_S3
    if _CACHED_S3 is None:
        _CACHED_S3 = get_session().client("s3")
    return _CACHED_S3


def get_route53_client():
    global _CACHED_ROUTE53
    if _CACHED_ROUTE53 is None:
        _CACHED_ROUTE53 = get_session().client("route53")
    return _CACHED_ROUTE53


def get_ec2_client():
    global _CACHED_EC2
    if _CACHED_EC2 is None:
        _CACHED_EC2 = get_session().client("ec2")
    return _CACHED_EC2


def get_lambda_client():
    global _CACHED_LAMBDA
    if _CACHED_LAMBDA is None:
        _CACHED_LAMBDA = get_session().client("lambda")
    return _CACHED_LAMBDA


# ---------------------------------------------------------------------------
# S3 IP management
# ---------------------------------------------------------------------------

def reset_ip_list(s3_client):
    resp = s3_client.get_bucket_policy(Bucket=BUCKET_NAME)
    policy = json.loads(resp["Policy"])
    ip_list = policy["Statement"][0]["Condition"]["IpAddress"]["aws:SourceIp"]
    # Keep only the default VPC CIDR ranges (172.x.x.x)
    reset_list = [x for x in ip_list if x.startswith("172")]
    policy["Statement"][0]["Condition"]["IpAddress"]["aws:SourceIp"] = reset_list
    s3_client.put_bucket_policy(Bucket=BUCKET_NAME, Policy=json.dumps(policy))


def add_ip(s3_client, ip_address):
    resp = s3_client.get_bucket_policy(Bucket=BUCKET_NAME)
    policy = json.loads(resp["Policy"])
    ip_list = policy["Statement"][0]["Condition"]["IpAddress"]["aws:SourceIp"]
    ip_list.append(f"{ip_address}/32")
    policy["Statement"][0]["Condition"]["IpAddress"]["aws:SourceIp"] = list(set(ip_list))
    s3_client.put_bucket_policy(Bucket=BUCKET_NAME, Policy=json.dumps(policy))


# ---------------------------------------------------------------------------
# ECS management
# ---------------------------------------------------------------------------

def notify_webhook(message):
    if not DISCORD_WEBHOOK_URL:
        return
    body = json.dumps({"content": message}).encode()
    req = urllib.request.Request(
        DISCORD_WEBHOOK_URL,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        urllib.request.urlopen(req, timeout=5)
    except Exception as exc:  # pylint: disable=broad-except
        print(f"Webhook notification failed: {exc}")


def ecs_action(ecs_client, action):
    if action == "START":
        desired = 1
    elif action == "STOP":
        desired = 0
    else:
        raise RuntimeError(f"Unknown ECS action: {action}")

    ecs_client.update_service(
        cluster=ECS_CLUSTER,
        service=ECS_SERVICE,
        desiredCount=desired,
    )
    msg = f"ECS service {ECS_SERVICE} desiredCount set to {desired}"
    notify_webhook(msg)
    return msg


def ecs_status(ecs_client):
    resp = ecs_client.describe_services(cluster=ECS_CLUSTER, services=[ECS_SERVICE])
    if not resp.get("services"):
        return {"status": "UNKNOWN", "desired": 0, "running": 0}
    service = resp["services"][0]
    return {
        "status": service["status"],
        "desired": service["desiredCount"],
        "running": service["runningCount"],
    }


# ---------------------------------------------------------------------------
# DNS update - called on ECS Task State Change (RUNNING), only when
# use_cloudfront = true (see the ecs_task_running EventBridge rule in lambda.tf)
# ---------------------------------------------------------------------------

def update_origin_dns(route53_client, ec2_client, task_detail):
    """Resolve the ECS task's public IP via its ENI and write it to the origin Route53 record."""
    eni_id = None
    for attachment in task_detail.get("attachments", []):
        if attachment.get("type") == "eni":
            for detail in attachment.get("details", []):
                if detail["name"] == "networkInterfaceId":
                    eni_id = detail["value"]
                    break

    if not eni_id:
        print("No ENI found in task attachments - skipping DNS update")
        return

    resp = ec2_client.describe_network_interfaces(NetworkInterfaceIds=[eni_id])
    public_ip = resp["NetworkInterfaces"][0].get("Association", {}).get("PublicIp")

    if not public_ip:
        print(f"No public IP on ENI {eni_id} - skipping DNS update")
        return

    route53_client.change_resource_record_sets(
        HostedZoneId=HOSTED_ZONE_ID,
        ChangeBatch={
            "Changes": [{
                "Action": "UPSERT",
                "ResourceRecordSet": {
                    "Name": ORIGIN_RECORD,
                    "Type": "A",
                    "TTL": 60,
                    "ResourceRecords": [{"Value": public_ip}],
                },
            }]
        },
    )
    print(f"Updated {ORIGIN_RECORD} to {public_ip}")


# ---------------------------------------------------------------------------
# Discord Interactions (slash commands over HTTPS webhook)
# ---------------------------------------------------------------------------

def verify_discord_signature(headers, raw_body):
    signature = headers.get("x-signature-ed25519")
    timestamp = headers.get("x-signature-timestamp")
    if not signature or not timestamp or not DISCORD_PUBLIC_KEY:
        return False
    try:
        verify_key = nacl.signing.VerifyKey(bytes.fromhex(DISCORD_PUBLIC_KEY))
        verify_key.verify((timestamp + raw_body).encode(), bytes.fromhex(signature))
        return True
    except (nacl.exceptions.BadSignatureError, ValueError):
        return False


def discord_response(body_dict):
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body_dict),
    }


def discord_message(content, ephemeral=False):
    data = {"content": content}
    if ephemeral:
        data["flags"] = DISCORD_EPHEMERAL_FLAG
    return discord_response({"type": 4, "data": data})


def discord_invoker_name(interaction):
    user = interaction.get("member", {}).get("user") or interaction.get("user", {})
    return user.get("global_name") or user.get("username") or "someone"


def edit_discord_interaction_response(application_id, token, content):
    """Update Discord's original interaction message via webhook PATCH."""
    url = f"https://discord.com/api/v10/webhooks/{application_id}/{token}/messages/@original"
    req = urllib.request.Request(
        url,
        data=json.dumps({"content": content}).encode(),
        headers={
            "Content-Type": "application/json",
            "User-Agent": "FoundryManagerLambda (https://github.com/samdammers/foundryvtt-aws-ecs-terraform, 1.0)",
        },
        method="PATCH",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            print(f"Discord original interaction updated (status {resp.status})")
    except urllib.error.URLError as exc:
        print(f"ERROR: failed to update Discord interaction response: {exc}")
        if hasattr(exc, "read"):
            try:
                print(f"Details: {exc.read().decode(errors='replace')}")
            except Exception:
                pass


def invoke_async_worker(payload, context=None):
    """Invoke this same Lambda function asynchronously with InvocationType='Event'."""
    lambda_client = get_lambda_client()
    function_name = (
        context.function_name
        if context and hasattr(context, "function_name")
        else os.environ.get("AWS_LAMBDA_FUNCTION_NAME", "foundry-manager")
    )
    lambda_client.invoke(
        FunctionName=function_name,
        InvocationType="Event",
        Payload=json.dumps(payload),
    )


def handle_discord_interaction(event, context):
    """
    Handle synchronous POST /discord webhook calls from Discord.
    
    Verifies signature and immediately returns:
    - type 1 (PONG) for PING (endpoint verification)
    - type 5 (DEFERRED_CHANNEL_MESSAGE_WITH_SOURCE) for slash commands,
      dispatching the actual work to an async Lambda invocation to guarantee
      response in <100ms and avoid Discord's 3-second timeout limit.
    """
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    raw_body = event.get("body") or ""
    if event.get("isBase64Encoded"):
        raw_body = base64.b64decode(raw_body).decode()

    if not verify_discord_signature(headers, raw_body):
        return {"statusCode": 401, "body": json.dumps("invalid request signature")}

    try:
        interaction = json.loads(raw_body)
    except Exception as exc:
        print(f"ERROR: invalid interaction JSON: {exc}")
        return {"statusCode": 400, "body": json.dumps("invalid json body")}

    interaction_type = interaction.get("type")

    # PING - Discord's endpoint-verification handshake.
    if interaction_type == 1:
        return discord_response({"type": 1})

    # APPLICATION_COMMAND - Slash commands.
    if interaction_type == 2:
        invoke_async_worker(
            {
                "async_action": "discord_command",
                "interaction": interaction,
            },
            context=context,
        )
        # Deferred response: Discord displays "Bot is thinking..." and allows up to 15m for followup
        return discord_response({"type": 5})

    return discord_message("Unsupported interaction type")


def process_discord_command(interaction):
    """Execute the slash command and format the response message."""
    command = interaction.get("data", {}).get("name")
    ecs_client = get_ecs_client()
    invoker = discord_invoker_name(interaction)

    try:
        if command == "foundry-start":
            status = ecs_status(ecs_client)
            if status["running"] > 0:
                content = f"Foundry is already running!\nJoin at {FOUNDRY_URL}"
                content += f"\nPictures not loading? Click {IP_ADD_URL} to allow your IP"
                content += f"\nChecked by {invoker}"
            elif status["desired"] > 0 and status["running"] == 0:
                content = f"Foundry is currently starting up (provisioning container)...\nJoin at {FOUNDRY_URL} once it's up"
                content += f"\nPictures not loading? Click {IP_ADD_URL} to allow your IP"
                content += f"\nChecked by {invoker}"
            else:
                content = ecs_action(ecs_client, "START")
                content += f"\nJoin at {FOUNDRY_URL} once it's up (give it a minute or two)"
                content += f"\nPictures not loading? Click {IP_ADD_URL} to allow your IP"
                content += f"\nStarted by {invoker}"
            return content

        if command == "foundry-stop":
            status = ecs_status(ecs_client)
            if status["desired"] == 0 and status["running"] == 0:
                content = f"Foundry is already stopped.\nChecked by {invoker}"
            else:
                content = ecs_action(ecs_client, "STOP")
                content += f"\nStopped by {invoker}"
            return content

        if command == "foundry-status":
            status = ecs_status(ecs_client)
            content = (
                f"Status: {status['status']}\n"
                f"Desired: {status['desired']}, Running: {status['running']}"
            )
            if status["running"] > 0:
                content += f"\nJoin at {FOUNDRY_URL}"
                content += f"\nPictures not loading? Click {IP_ADD_URL} to allow your IP"
            elif status["desired"] > 0 and status["running"] == 0:
                content += "\n*(Starting up, container provisioning...)*"
            return content

        return f"Unknown command: {command}"
    except Exception as exc:  # pylint: disable=broad-except
        print(f"ERROR: failed executing command '{command}': {exc}")
        return f":warning: Failed to execute `/{command}`: {exc}"


def handle_async_discord_command(event):
    """Handle asynchronous background execution of a Discord slash command."""
    interaction = event.get("interaction", {})
    app_id = interaction.get("application_id")
    token = interaction.get("token")

    if not app_id or not token:
        print("ERROR: missing application_id or token in async discord interaction event")
        return

    content = process_discord_command(interaction)
    edit_discord_interaction_response(app_id, token, content)


# ---------------------------------------------------------------------------
# Lambda handler
# ---------------------------------------------------------------------------

def lambda_handler(event, context):
    print(json.dumps(event))

    # Asynchronous Discord slash command worker
    if event.get("async_action") == "discord_command":
        handle_async_discord_command(event)
        return {"statusCode": 200, "body": json.dumps("ok")}

    # ECS task state change - update origin DNS record
    if event.get("source") == "aws.ecs":
        if (event.get("detail-type") == "ECS Task State Change"
                and event.get("detail", {}).get("lastStatus") == "RUNNING"
                and HOSTED_ZONE_ID
                and ORIGIN_RECORD):
            update_origin_dns(
                get_route53_client(),
                get_ec2_client(),
                event["detail"],
            )
        return {"statusCode": 200, "body": json.dumps("DNS updated")}

    route = event.get("path", "")

    # Synchronous API Gateway /discord route
    if route == "/discord":
        try:
            return handle_discord_interaction(event, context)
        except Exception as exc:  # pylint: disable=broad-except
            print(f"ERROR in handle_discord_interaction: {exc}")
            return {"statusCode": 500, "body": json.dumps(str(exc))}

    # Scheduled EventBridge events with custom input
    scheduled_action = event.get("scheduled_action")
    if scheduled_action == "ecs_stop":
        ecs_action(get_ecs_client(), "STOP")
        return {"statusCode": 200, "body": json.dumps("ECS service stopped by schedule")}

    # Scheduled EventBridge event - reset IPs daily (legacy: no custom input)
    if event.get("detail-type") == "Scheduled Event":
        reset_ip_list(get_s3_client())
        return {"statusCode": 200, "body": json.dumps("IP list reset")}

    if event.get("httpMethod", "GET") != "GET":
        return {"statusCode": 400, "body": json.dumps("Bad Request")}

    try:
        if route == "/ip/reset":
            reset_ip_list(get_s3_client())
            msg = "IP list reset"

        elif route == "/ip/add":
            forwarded_for = (event.get("headers") or {}).get("X-Forwarded-For", "")
            if not forwarded_for:
                return {"statusCode": 400, "body": json.dumps("Cannot determine caller IP")}
            # X-Forwarded-For may be comma-separated; take the first (client) IP
            ip = forwarded_for.split(",")[0].strip()
            add_ip(get_s3_client(), ip)
            msg = f"IP {ip} added"

        elif route == "/stop":
            msg = ecs_action(get_ecs_client(), "STOP")

        elif route == "/start":
            msg = ecs_action(get_ecs_client(), "START")

        elif route == "/status":
            return {"statusCode": 200, "body": json.dumps(ecs_status(get_ecs_client()))}

        else:
            return {"statusCode": 404, "body": json.dumps(f"Unknown route: {route}")}

    except Exception as exc:  # pylint: disable=broad-except
        print(f"ERROR: {exc}")
        return {"statusCode": 500, "body": json.dumps(str(exc))}

    return {"statusCode": 200, "body": json.dumps(msg)}
