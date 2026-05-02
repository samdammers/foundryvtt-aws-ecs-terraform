"""
FoundryVTT management Lambda.

Routes:
  GET /start       — Scale ECS Foundry service to 1 task
  GET /stop        — Scale ECS Foundry service to 0 tasks
  GET /ip/add      — Add caller IP to S3 bucket policy allowlist
  GET /ip/reset    — Reset S3 bucket policy to VPC CIDRs only
Scheduled event    — Triggers /ip/reset daily at 1am AEST
Scheduled event    — Stops ECS service on auto_stop schedule (scheduled_action=ecs_stop)
"""
import json
import os

import boto3

BUCKET_NAME = os.environ["S3_BUCKET"]
ECS_CLUSTER = os.environ.get("ECS_CLUSTER", "foundry")
ECS_SERVICE = os.environ.get("ECS_SERVICE", "foundry")


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
    return f"ECS service {ECS_SERVICE} desiredCount set to {desired}"


# ---------------------------------------------------------------------------
# Lambda handler
# ---------------------------------------------------------------------------

def lambda_handler(event, context):
    print(json.dumps(event))
    sess = boto3.session.Session()

    # Scheduled EventBridge events with custom input
    scheduled_action = event.get("scheduled_action")
    if scheduled_action == "ecs_stop":
        ecs_action(sess.client("ecs"), "STOP")
        return {"statusCode": 200, "body": json.dumps("ECS service stopped by schedule")}

    # Scheduled EventBridge event — reset IPs daily (legacy: no custom input)
    if event.get("detail-type") == "Scheduled Event":
        reset_ip_list(sess.client("s3"))
        return {"statusCode": 200, "body": json.dumps("IP list reset")}

    if event.get("httpMethod", "GET") != "GET":
        return {"statusCode": 400, "body": json.dumps("Bad Request")}

    route = event.get("path", "")

    try:
        if route == "/ip/reset":
            reset_ip_list(sess.client("s3"))
            msg = "IP list reset"

        elif route == "/ip/add":
            forwarded_for = (event.get("headers") or {}).get("X-Forwarded-For", "")
            if not forwarded_for:
                return {"statusCode": 400, "body": json.dumps("Cannot determine caller IP")}
            # X-Forwarded-For may be comma-separated; take the first (client) IP
            ip = forwarded_for.split(",")[0].strip()
            add_ip(sess.client("s3"), ip)
            msg = f"IP {ip} added"

        elif route == "/stop":
            msg = ecs_action(sess.client("ecs"), "STOP")

        elif route == "/start":
            msg = ecs_action(sess.client("ecs"), "START")

        else:
            return {"statusCode": 404, "body": json.dumps(f"Unknown route: {route}")}

    except Exception as exc:  # pylint: disable=broad-except
        print(f"ERROR: {exc}")
        return {"statusCode": 500, "body": json.dumps(str(exc))}

    return {"statusCode": 200, "body": json.dumps(msg)}
