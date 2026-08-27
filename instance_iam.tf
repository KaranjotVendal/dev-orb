# IAM for the runner VM. One least-privilege identity: the INSTANCE role the box runs
# as — SSM Session Manager (shell + port-forward, NO SSH) + read-only on the box's SSM
# parameter subtree (the GitHub token orb reads at setup) + KMS-decrypt via SSM.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

# --- Instance role -----------------------------------------------------------

data "aws_iam_policy_document" "instance_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "${var.name}-instance"
  assume_role_policy = data.aws_iam_policy_document.instance_assume.json
}

# SSM Session Manager: shell + port-forward without opening SSH. The AWS-managed
# policy grants the ssm:* / ssmmessages:* the agent needs to register and serve
# sessions (including AWS-StartPortForwardingSession / AWS-StartSSHSession).
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Runtime secrets: read the box's SSM parameter subtree and decrypt the SecureString
# values via the SSM-scoped KMS key. Scoped to the ssm_prefix subtree — no wildcard
# resource beyond it.
data "aws_iam_policy_document" "instance_runtime" {
  statement {
    sid    = "SsmParamRead"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]
    # ssm_prefix already starts with "/", so no slash between `parameter` and it.
    resources = ["arn:${data.aws_partition.current.partition}:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter${var.ssm_prefix}/*"]
  }

  statement {
    sid       = "SsmKmsDecrypt"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    # Restrict decrypt to keys used via SSM — the standard pattern for the
    # AWS-managed alias/aws/ssm key, whose ARN we can't reference directly.
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${data.aws_region.current.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "instance_runtime" {
  name   = "runtime-secrets"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.instance_runtime.json
}

resource "aws_iam_instance_profile" "instance" {
  name = "${var.name}-instance"
  role = aws_iam_role.instance.name
}
