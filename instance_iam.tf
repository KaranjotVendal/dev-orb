# IAM for the runner VM. Two least-privilege identities:
#
#  1. The INSTANCE role the box runs as: SSM Session Manager (shell + port-forward,
#     NO SSH) + read-only on the box's SSM SecureString subtree + KMS-decrypt via
#     SSM. The jot-server ECR-pull grant is DROPPED (no registry).
#  2. The narrow BROKER role the laptop assumes to push the daily token: ssm:PutParameter
#     on JUST the id-token parameter + the matching KMS-encrypt. It cannot read, cannot
#     touch the seat bundles, cannot write any other parameter.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  token_param_arn = "arn:${data.aws_partition.current.partition}:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter${local.token_param_name}"
}

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

  # Cache transfer: the VM UPLOADS the daily serving cache + sessions to the pre-existing
  # operator-managed bucket (var.cache_bucket), which the laptop/SPCS side then fetches.
  # Upload-ONLY least privilege — the VM never reads back, never deletes, never touches
  # bucket policy/ACLs. ListBucket is needed by `aws s3 sync` to diff before upload.
  # Scoped to just this bucket's ARNs (no wildcard). This is durable artifact STAGING,
  # not serving — the human-gated SPCS /restore stays off the VM (INV-2).
  statement {
    sid       = "CacheBucketList"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:${data.aws_partition.current.partition}:s3:::${var.cache_bucket}"]
  }

  statement {
    sid       = "CacheBucketUpload"
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:AbortMultipartUpload"]
    resources = ["arn:${data.aws_partition.current.partition}:s3:::${var.cache_bucket}/*"]
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

# --- Laptop broker role (narrow token push) ----------------------------------

# The laptop broker assumes this role to push the daily id-token. It trusts ONLY the
# configured laptop principal; an empty broker_principal_arn yields a policy that
# trusts no one, so the role fails closed until GATE 2 supplies the ARN.
data "aws_iam_policy_document" "broker_assume" {
  count = var.broker_principal_arn == "" ? 0 : 1

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = [var.broker_principal_arn]
    }
  }
}

resource "aws_iam_role" "broker" {
  count              = var.broker_principal_arn == "" ? 0 : 1
  name               = "${var.name}-broker"
  assume_role_policy = data.aws_iam_policy_document.broker_assume[0].json
}

# The broker may write ONLY the id-token parameter, and encrypt it with the SSM KMS
# key. No read, no other parameter, no wildcard.
data "aws_iam_policy_document" "broker_put_token" {
  count = var.broker_principal_arn == "" ? 0 : 1

  statement {
    sid       = "SsmPutTokenOnly"
    effect    = "Allow"
    actions   = ["ssm:PutParameter"]
    resources = [local.token_param_arn]
  }

  statement {
    sid       = "SsmKmsEncrypt"
    effect    = "Allow"
    actions   = ["kms:Encrypt", "kms:GenerateDataKey"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${data.aws_region.current.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "broker_put_token" {
  count  = var.broker_principal_arn == "" ? 0 : 1
  name   = "put-token-only"
  role   = aws_iam_role.broker[0].id
  policy = data.aws_iam_policy_document.broker_put_token[0].json
}
