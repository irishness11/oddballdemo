# ---- VPC (no NAT, public subnets used by nodes) ----
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "oddball-vpc"
  cidr = "10.0.0.0/16"
  azs  = ["us-east-2a","us-east-2b"]

  # Keep both sets for flexibility, but nodes will be in PUBLIC subnets
  private_subnets = ["10.0.0.0/19", "10.0.32.0/19"]
  public_subnets  = ["10.0.96.0/23", "10.0.98.0/23"]

  # Disable NAT gateway to avoid costs
  enable_nat_gateway = false
}

# ---- EKS (workers in PUBLIC subnets, small instances) ----
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = "1.30"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnets

  enable_irsa = true

  eks_managed_node_groups = {
    default = {
      desired_size   = 2
      min_size       = 1
      max_size       = 2
      instance_types = ["t2.micro"]
      capacity_type  = "ON_DEMAND"
      update_config  = { max_unavailable_percentage = 33 }
    }
  }
}

# ---- ECR ----
resource "aws_ecr_repository" "app" {
  name = "oddball-svc"
  image_scanning_configuration { scan_on_push = true }
  encryption_configuration { encryption_type = "KMS" }
}

