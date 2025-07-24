module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.31.3"

  cluster_name    = local.eks_cluster_name
  cluster_version = "1.31"

  # Give the Terraform identity admin access to the cluster
  # which will allow it to deploy resources into the cluster
  enable_cluster_creator_admin_permissions = true
  cluster_endpoint_public_access           = true

  access_entries = merge(
    {
      admin = {
        kubernetes_groups = []
        principal_arn     = aws_iam_role.eks_cluster_access.arn

        policy_associations = {
          cluster = {
            policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
            access_scope = {
              type = "cluster"
            }
          }
        }
      }
      readonly = {
        kubernetes_groups = []
        principal_arn     = aws_iam_role.readonly_clusterrole.arn

        policy_associations = {
          cluster = {
            policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminViewPolicy"
            access_scope = {
              type = "cluster"
            }
          }
        }
      }
    },
    # Only create github_actions access entry on production cluster, since that's
    # the only one we run the TF drift detection job on.
    var.deployment_name == "prod" ? {
      github_actions_drift_detection = {
        kubernetes_groups = []
        principal_arn     = aws_iam_role.github_actions[0].arn

        policy_associations = {
          cluster = {
            policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminViewPolicy"
            access_scope = {
              type = "cluster"
            }
          }
        }
      }
  } : {})

  cluster_addons = {
    coredns = {
      addon_version = "v1.11.4-eksbuild.2"
    }
    eks-pod-identity-agent = {
      addon_version = "v1.3.4-eksbuild.1"
    }
    kube-proxy = {
      addon_version = "v1.31.3-eksbuild.2"
    }
    vpc-cni = {
      addon_version = "v1.19.0-eksbuild.1"
    }
    aws-ebs-csi-driver = {
      addon_version            = "v1.38.1-eksbuild.2"
      service_account_role_arn = aws_iam_role.ebs_csi_driver.arn
    }
    aws-efs-csi-driver = {
      addon_version            = "v2.1.4-eksbuild.1"
      service_account_role_arn = aws_iam_role.efs_csi_driver.arn
    }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    bootstrap-node-group = {
      instance_types = ["m5.large"]

      min_size     = 2
      max_size     = 3
      desired_size = 2

      labels = {
        # Used to ensure Karpenter runs on nodes that it does not manage
        "karpenter.sh/controller" = "true"
      }

      taints = {
        # The pods that do not tolerate this taint should run on nodes
        # created by Karpenter
        critical-addons-only = {
          key    = "CriticalAddonsOnly"
          effect = "NO_SCHEDULE"
        }
      }
    }
  }

  node_security_group_name            = "${local.eks_cluster_name}-node-sg"
  node_security_group_use_name_prefix = false
  node_security_group_tags = {
    "karpenter.sh/discovery" = local.eks_cluster_name
  }
  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true # Only apply this rule to other nodes in this security group
    }
  }
}

resource "aws_iam_role" "ebs_csi_driver" {
  name = "AmazonEKS_EBS_CSI_DriverRole-${var.deployment_name}"
  assume_role_policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Principal" : {
          "Federated" : module.eks.oidc_provider_arn
        },
        "Action" : "sts:AssumeRoleWithWebIdentity",
        "Condition" : {
          "StringEquals" : {
            "${module.eks.oidc_provider}:sub" : "system:serviceaccount:kube-system:ebs-csi-controller-sa",
            "${module.eks.oidc_provider}:aud" : "sts.amazonaws.com"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi_driver" {
  role       = aws_iam_role.ebs_csi_driver.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy" # AWS managed policy
}

resource "aws_iam_role" "efs_csi_driver" {
  name = "AmazonEKS_EFS_CSI_DriverRole-${var.deployment_name}"
  assume_role_policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Principal" : {
          "Federated" : module.eks.oidc_provider_arn
        },
        "Action" : "sts:AssumeRoleWithWebIdentity",
        "Condition" : {
          "StringEquals" : {
            "${module.eks.oidc_provider}:sub" : "system:serviceaccount:kube-system:efs-csi-*",
            "${module.eks.oidc_provider}:aud" : "sts.amazonaws.com"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "efs_csi_driver" {
  role       = aws_iam_role.efs_csi_driver.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy" # AWS managed policy
}

resource "aws_iam_role" "eks_cluster_access" {
  name = "SpackEKSClusterAccess-${var.deployment_name}-${var.deployment_stage}"
  assume_role_policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Principal" : {
          "AWS" : [
            "arn:aws:iam::588562868276:user/scott",
            "arn:aws:iam::588562868276:user/jacob",
            "arn:aws:iam::588562868276:user/krattiger1",
            "arn:aws:iam::588562868276:user/mike",
            "arn:aws:iam::588562868276:user/zack",
            "arn:aws:iam::588562868276:user/dan",
            "arn:aws:iam::588562868276:user/william",
            "arn:aws:iam::588562868276:user/caetanomelone",
          ]
        },
        "Action" : "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "eks_cluster_access" {
  name = "SpackEKSClusterAccess-${var.deployment_name}-${var.deployment_stage}"
  role = aws_iam_role.eks_cluster_access.id
  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Action" : [
          "eks:ListAccessEntries",
          "eks:DescribeAccessEntry",
          "eks:UpdateAccessEntry",
          "eks:ListAccessPolicies",
          "eks:AssociateAccessPolicy",
          "eks:DisassociateAccessPolicy"
        ],
        "Resource" : "*"
      },
    ]
  })
}

resource "aws_iam_role" "readonly_clusterrole" {
  name = "SpackEKSReadOnlyClusterAccess-${var.deployment_name}-${var.deployment_stage}"
  assume_role_policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Principal" : {
          "AWS" : [
            "arn:aws:iam::588562868276:user/joesnyder",
            "arn:aws:iam::588562868276:user/alecscott",
            "arn:aws:iam::588562868276:user/tgamblin",
            "arn:aws:iam::588562868276:user/vsoch",
            "arn:aws:iam::588562868276:user/caetanomelone",
          ]
        },
        "Action" : "sts:AssumeRole"
      }
    ]
  })
}

# Define a configmap that provides the EKS Cluster name
resource "kubectl_manifest" "cluster_name_config_map" {
  yaml_body = <<-YAML
    apiVersion: v1
    kind: ConfigMap
    metadata:
        name: cluster-info
        namespace: kube-system
    data:
        cluster-name: ${module.eks.cluster_name}
  YAML
}
