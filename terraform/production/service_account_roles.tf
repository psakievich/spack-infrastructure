# The IAM role to enable signing runners
resource "aws_iam_role" "notary" {
  name = "NotaryRole"
  assume_role_policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Principal" : {
          "Federated" : module.production_cluster.oidc_provider_arn
        },
        "Action" : "sts:AssumeRoleWithWebIdentity",
        "Condition" : {
          "StringEquals" : {
            "${module.production_cluster.oidc_provider}:aud" : "sts.amazonaws.com"
          }
        }
      }
    ]
  })
}

# The policy to allow for KMS key decryption and S3 Access
resource "aws_iam_role_policy" "notary" {
  name = "NotaryPolicy"
  role = aws_iam_role.notary.id
  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      # Reputational Encryption Key
      {
        "Effect" : "Allow",
        "Action" : [
          "kms:GetPublicKey",
          "kms:Decrypt",
          "kms:DescribeKey"
        ],
        "Resource" : "arn:aws:kms:us-east-1:588562868276:key/bc739d17-8569-4741-9385-9264715b90b6"
      },
      # Test Key
      {
        "Effect" : "Allow",
        "Action" : [
          "kms:GetPublicKey",
          "kms:Decrypt",
          "kms:DescribeKey"
        ],
        "Resource" : "arn:aws:kms:us-east-1:588562868276:key/e811e4c5-ea63-4da3-87d4-664dc5395169"
      },
      # S3 Full Access
      {
        "Effect" : "Allow",
        "Action" : [
          "s3:*",
          "s3-object-lambda:*"
        ],
        "Resource" : "*"
      }
    ]
  })
}

# The ServiceAccount to be used by the signing runner
resource "kubectl_manifest" "notary_service_account" {
  yaml_body = <<-YAML
    apiVersion: v1
    kind: ServiceAccount
    metadata:
      name: notary
      namespace: pipeline
      annotations:
        # NotaryRole
        eks.amazonaws.com/role-arn: ${aws_iam_role.notary.arn}
  YAML
  depends_on = [
    aws_iam_role_policy.notary
  ]
}

# The IAM role granting Spackbot full access to spack-binaries-prs S3 bucket.
resource "aws_iam_role" "full_crud_access_spack_binaries_prs" {
  name        = "FullCRUDAccessToBucketSpackBinariesPRs"
  description = "Managed by Terraform. Grants Kubernetes pods access to read/write/delete objects from the spack-binaries-prs S3 bucket."
  assume_role_policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Principal" : {
          "Federated" : module.production_cluster.oidc_provider_arn
        },
        "Action" : "sts:AssumeRoleWithWebIdentity",
        "Condition" : {
          "StringEquals" : {
            "${module.production_cluster.oidc_provider}:aud" : "sts.amazonaws.com"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "put_spack_binaries_prs" {
  name = "PutObjectsInBucketSpackBinariesPRs"
  role = aws_iam_role.full_crud_access_spack_binaries_prs.id
  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Action" : "s3:PutObject",
        "Resource" : "arn:aws:s3:::spack-binaries-prs/*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "delete_spack_binaries_prs" {
  name = "DeleteObjectsFromBucketSpackBinariesPRs"
  role = aws_iam_role.full_crud_access_spack_binaries_prs.id
  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Action" : "s3:DeleteObject",
        "Resource" : "arn:aws:s3:::spack-binaries-prs/*"
      }
    ]
  })
}

# Create the spackbot-spack-io and spackbotdev-spack-io ServiceAccounts
resource "kubectl_manifest" "spackbot_service_account" {
  for_each  = toset(["spackbot", "spackbotdev"])
  yaml_body = <<-YAML
    apiVersion: v1
    kind: ServiceAccount
    metadata:
      name: ${each.value}-spack-io
      namespace: spack
      annotations:
        # FullCRUDAccessToBucketSpackBinariesPRs
        eks.amazonaws.com/role-arn: ${aws_iam_role.full_crud_access_spack_binaries_prs.arn}
  YAML
  depends_on = [
    aws_iam_role_policy.put_spack_binaries_prs,
    aws_iam_role_policy.delete_spack_binaries_prs
  ]
}

resource "aws_iam_role" "put_object_in_pipeline_statistics" {
  name        = "PutObjectInPipelineStatistics"
  description = "Managed by Terraform. Grant access to write to the pipeline-statistics folder of the spack-logs bucket."
  assume_role_policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Principal" : {
          "Federated" : module.production_cluster.oidc_provider_arn
        },
        "Action" : "sts:AssumeRoleWithWebIdentity",
        "Condition" : {
          "StringEquals" : {
            "${module.production_cluster.oidc_provider}:aud" : "sts.amazonaws.com"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "put_object_in_pipeline_statistics" {
  name = "PutObjectInPipelineStatistics"
  role = aws_iam_role.put_object_in_pipeline_statistics.id
  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Action" : "s3:PutObject",
        "Resource" : "arn:aws:s3:::spack-logs/pipeline-statistics/*"
      }
    ]
  })
}

# The ServiceAccount to be used by the gitlab pipeline stats job
resource "kubectl_manifest" "gitlab_api_scrape_service_account" {
  yaml_body = <<-YAML
    apiVersion: v1
    kind: ServiceAccount
    metadata:
      name: gitlab-api-scrape
      namespace: custom
      annotations:
        # PutObjectInPipelineStatistics
        eks.amazonaws.com/role-arn: ${aws_iam_role.put_object_in_pipeline_statistics.arn}
  YAML
  depends_on = [
    aws_iam_role_policy.put_object_in_pipeline_statistics
  ]
}