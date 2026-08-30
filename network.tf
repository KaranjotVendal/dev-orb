# Network for the runner VM: the account's default VPC, a deterministically-picked
# subnet, the Ubuntu LTS AMI, and a locked-down security group.
#
# SECURITY POSTURE (INV / cloud-security): NO inbound rules at all — the box is not
# reachable from the internet. Shell + code-deploy tunnel are via SSM Session
# Manager (which rides the instance's OUTBOUND connection to the SSM endpoints, not
# any ingress rule), so no SSH ingress and no public listener exist. Egress is open
# so the box can reach SSM, the agent/model APIs, and the mise / apt / npm sources
# at boot.

# A single interim box doesn't justify a bespoke VPC — use the account's default.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

locals {
  # Deterministic pick of one subnet so re-applies don't churn the instance/EBS AZ.
  instance_subnet_id = sort(data.aws_subnets.default.ids)[0]
}

# Resolve the picked subnet for its availability_zone — the EBS volume must live in
# the same AZ as the instance.
data "aws_subnet" "selected" {
  id = local.instance_subnet_id
}

# Ubuntu 24.04 LTS (Canonical). The bootstrap toolchain is apt-based (bubblewrap +
# mise.run + per-user npm); Canonical LTS ships the SSM agent (snap) preinstalled,
# so Session Manager works out of the box.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# No-ingress security group: the box has no public listener. Egress-only.
resource "aws_security_group" "instance" {
  name        = "${var.name}-instance"
  description = "Runner VM: NO inbound (shell + deploy via SSM Session Manager only); egress all."
  vpc_id      = data.aws_vpc.default.id

  egress {
    description = "All outbound - the box reaches SSM, the agent/model APIs, and boot package sources."
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
