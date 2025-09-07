output "region"          { value = var.region }
output "cluster_name"    { value = module.eks.cluster_name }
output "ecr_repo_url"    { value = aws_ecr_repository.app.repository_url }
output "private_subnets" { value = module.vpc.private_subnets }
output "public_subnets"  { value = module.vpc.public_subnets }
