# ===== BEGIN bootstrap_oddball_repo.sh =====
#!/usr/bin/env bash
set -euo pipefail

mkdir -p oddball-iac chart/templates app ansible .github/workflows .vscode

# --- Terraform ---
cat > oddball-iac/providers.tf <<'EOF'
terraform {
  required_version = ">= 1.4.0"
  required_providers { aws = { source = "hashicorp/aws", version = "~> 5.0" } }
}
provider "aws" { region = var.region }
EOF

cat > oddball-iac/variables.tf <<'EOF'
variable "region"       { type = string, default = "us-east-2" }
variable "cluster_name" { type = string, default = "oddball-eks" }
EOF

cat > oddball-iac/main.tf <<'EOF'
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"
  name = "oddball-vpc"
  cidr = "10.0.0.0/16"
  azs  = ["us-east-2a","us-east-2b"]
  private_subnets = ["10.0.0.0/19", "10.0.32.0/19"]
  public_subnets  = ["10.0.96.0/23", "10.0.98.0/23"]
  enable_nat_gateway = true
  single_nat_gateway = true
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"
  cluster_name    = var.cluster_name
  cluster_version = "1.30"
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets
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

resource "aws_ecr_repository" "app" {
  name = "oddball-svc"
  image_scanning_configuration { scan_on_push = true }
  encryption_configuration { encryption_type = "KMS" }
}
EOF

cat > oddball-iac/outputs.tf <<'EOF'
output "region"          { value = var.region }
output "cluster_name"    { value = module.eks.cluster_name }
output "ecr_repo_url"    { value = aws_ecr_repository.app.repository_url }
output "private_subnets" { value = module.vpc.private_subnets }
output "public_subnets"  { value = module.vpc.public_subnets }
EOF

# --- App ---
cat > app/app.py <<'EOF'
from flask import Flask, jsonify
app = Flask(__name__)
@app.get("/")
def health():
    return jsonify(message="Hello Oddball!", status="ok")
EOF

cat > app/requirements.txt <<'EOF'
flask==3.0.3
gunicorn==22.0.0
EOF

cat > app/Dockerfile <<'EOF'
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
EXPOSE 8080
CMD ["gunicorn","-b","0.0.0.0:8080","app:app"]
EOF

# --- Helm chart ---
cat > chart/Chart.yaml <<'EOF'
apiVersion: v2
name: oddball-svc
version: 0.1.0
EOF

cat > chart/values.yaml <<'EOF'
image:
  repository: REPLACE_ME_ECR_URL
  tag: "latest"
replicaCount: 2
service:
  type: LoadBalancer
  port: 80
  targetPort: 8080
EOF

cat > chart/templates/deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: oddball-svc
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels: { app: oddball-svc }
  template:
    metadata:
      labels: { app: oddball-svc }
    spec:
      containers:
      - name: app
        image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
        ports: [{ containerPort: {{ .Values.service.targetPort }} }]
EOF

cat > chart/templates/service.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: oddball-svc
spec:
  selector: { app: oddball-svc }
  ports:
  - port: {{ .Values.service.port }}
    targetPort: {{ .Values.service.targetPort }}
  type: {{ .Values.service.type }}
EOF

# --- Ansible ---
cat > ansible/ansible.cfg <<'EOF'
[defaults]
inventory = ./inventory.ini
host_key_checking = False
EOF

cat > ansible/inventory.ini <<'EOF'
[local]
localhost ansible_connection=local
EOF

cat > ansible/deploy.yml <<'EOF'
- name: Deploy Oddball service to EKS with Helm
  hosts: local
  gather_facts: false
  collections: [kubernetes.core]
  vars:
    release_name: oddball-svc
    namespace: default
    kubeconfig: "{{ lookup('env','KUBECONFIG') | default('~/.kube/config') }}"
    image_repo: "{{ lookup('env','ECR_REPO') | default('') }}"
  tasks:
    - name: Ensure namespace exists
      k8s:
        kubeconfig: "{{ kubeconfig }}"
        api_version: v1
        kind: Namespace
        name: "{{ namespace }}"
        state: present
    - name: Helm upgrade/install
      helm:
        kubeconfig: "{{ kubeconfig }}"
        name: "{{ release_name }}"
        chart_path: "{{ playbook_dir }}/../chart"
        release_namespace: "{{ namespace }}"
        values:
          image:
            repository: "{{ image_repo }}"
            tag: "latest"
EOF

# --- GitHub Actions ---
cat > .github/workflows/infra.yml <<'EOF'
name: terraform-infra
on:
  workflow_dispatch:
  schedule: [ { cron: "0 9 * * 1" } ]
jobs:
  apply:
    runs-on: ubuntu-latest
    env: { AWS_REGION: us-east-2 }
    steps:
      - uses: actions/checkout@v4
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id:     ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region:            ${{ env.AWS_REGION }}
      - uses: hashicorp/setup-terraform@v3
      - name: Terraform Init/Plan/Apply
        working-directory: oddball-iac
        run: |
          terraform init
          terraform plan -out tfplan
          terraform apply -auto-approve tfplan
EOF

cat > .github/workflows/app.yml <<'EOF'
name: build-scan-push-deploy
on:
  push: { branches: [ "main" ] }
  workflow_dispatch:
env:
  AWS_REGION:    ${{ secrets.AWS_REGION }}
  ECR_REPO:      ${{ secrets.ECR_REPO }}
  K8S_NAMESPACE: ${{ secrets.K8S_NAMESPACE || 'default' }}
jobs:
  ci:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id:     ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region:            ${{ env.AWS_REGION }}
      - uses: aws-actions/amazon-ecr-login@v2
      - name: Build image
        run: docker build -t $ECR_REPO:latest ./app
      - name: Trivy scan (non-blocking)
        uses: aquasecurity/trivy-action@0.20.0
        with:
          image-ref: ${{ env.ECR_REPO }}:latest
          exit-code: '0'
      - name: Push image
        run: docker push $ECR_REPO:latest
      - uses: azure/setup-helm@v4
      - name: Update kubeconfig
        run: aws eks update-kubeconfig --name oddball-eks --region $AWS_REGION
      - name: Helm upgrade
        run: |
          helm upgrade --install oddball-svc ./chart \
            --namespace "$K8S_NAMESPACE" --create-namespace \
            --set image.repository="$ECR_REPO" --set image.tag=latest
EOF

# --- VS Code + gitignore ---
cat > .vscode/extensions.json <<'EOF'
{ "recommendations": [
  "hashicorp.terraform","redhat.vscode-yaml",
  "ms-azuretools.vscode-docker","ms-kubernetes-tools.vscode-kubernetes-tools",
  "redhat.ansible","github.vscode-github-actions"
]}
EOF

cat > .gitignore <<'EOF'
.terraform/
*.tfstate*
crash.log
*.tfvars
__pycache__/
EOF

echo "Scaffold complete (us-east-2, t2.micro)."
# ===== END bootstrap_oddball_repo.sh =====

