resource "aws_efs_file_system" "foundry" {
  creation_token = "foundry-data"
  encrypted      = true

  tags = merge(local.tags, { Name = "foundry-efs" })
}

# One mount target per AZ so the Fargate task can mount regardless of which AZ it lands in
resource "aws_efs_mount_target" "foundry" {
  for_each = toset(var.subnet_ids)

  file_system_id  = aws_efs_file_system.foundry.id
  subnet_id       = each.value
  security_groups = [aws_security_group.efs.id]
}

# Access point locks the container into /foundrydata and runs as uid 421
# (the 'foundry' user inside ghcr.io/felddy/foundryvtt)
resource "aws_efs_access_point" "foundry" {
  file_system_id = aws_efs_file_system.foundry.id

  posix_user {
    uid = 421
    gid = 421
  }

  root_directory {
    path = "/foundrydata"
    creation_info {
      owner_uid   = 421
      owner_gid   = 421
      permissions = "755"
    }
  }

  tags = merge(local.tags, { Name = "foundry-ap" })
}
