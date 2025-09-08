2) Drop-in README.md (copy/paste)
# Oddball EKS Demo (Terraform + ECR + EKS)

End-to-end demo that provisions AWS networking + EKS via Terraform, builds a tiny container, pushes to ECR, and serves it through an internet-facing LoadBalancer on EKS.

## Prerequisites
- AWS account with an IAM user (e.g., `OddballDemo`)
- AWS CLI v2, Docker, kubectl, Terraform (v1.5+ recommended)
- Credentials configured:

`~/.aws/config`
```ini
[profile oddball]
region = us-east-2
output = json


~/.aws/credentials

[oddball]
aws_access_key_id = <YOUR_KEY_ID>
aws_secret_access_key = <YOUR_SECRET>


Terraform’s AWS provider is pinned to use the oddball profile.

Repo Layout (IaC)
oddball-iac/
├─ main.tf            # VPC, EKS, ECR modules & outputs
├─ variables.tf       # input vars (region, project_name, cluster_name, subnets, repository_name)
├─ terraform.tfvars   # values for the vars
└─ oddball-deploy.yaml # k8s Deployment + Service (LoadBalancer)

Deploy Infra (Terraform)
cd oddball-iac
terraform init -upgrade
terraform plan -out=tfplan
terraform apply tfplan

Outputs (examples)

cluster_endpoint – EKS API endpoint

cluster_name – e.g. oddball-eks

ecr_repo_arn – ARN for the oddball-svc repo

vpc_id – created VPC id

Configure kubectl
AWS_PROFILE=oddball aws eks update-kubeconfig --region us-east-2 --name oddball-eks
kubectl get nodes

Build & Push App Image (Hello, Oddball!)

Create a minimal Dockerfile:

# Dockerfile
FROM nginx:alpine
RUN printf "Hello, Oddball!\n" > /usr/share/nginx/html/index.html


Build, tag, and push to ECR:

docker build -t oddball-svc:v2 .
docker tag oddball-svc:v2 891890914603.dkr.ecr.us-east-2.amazonaws.com/oddball-svc:v2

AWS_PROFILE=oddball aws ecr get-login-password --region us-east-2 \
  | docker login --username AWS --password-stdin 891890914603.dkr.ecr.us-east-2.amazonaws.com

docker push 891890914603.dkr.ecr.us-east-2.amazonaws.com/oddball-svc:v2

Deploy to EKS

oddball-deploy.yaml (already in repo) points to the ECR image and exposes a LoadBalancer:

apiVersion: apps/v1
kind: Deployment
metadata:
  name: oddball-svc
spec:
  replicas: 2
  selector:
    matchLabels: { app: oddball-svc }
  template:
    metadata: { labels: { app: oddball-svc } }
    spec:
      containers:
        - name: oddball-svc
          image: 891890914603.dkr.ecr.us-east-2.amazonaws.com/oddball-svc:v2
          imagePullPolicy: Always
          ports: [{ containerPort: 80 }]
          readinessProbe: { httpGet: { path: "/", port: 80 }, initialDelaySeconds: 5, periodSeconds: 5 }
          livenessProbe:  { httpGet: { path: "/", port: 80 }, initialDelaySeconds: 10, periodSeconds: 10 }
          resources:
            requests: { cpu: "100m", memory: "128Mi" }
            limits:   { cpu: "500m", memory: "256Mi" }
---
apiVersion: v1
kind: Service
metadata:
  name: oddball-svc
spec:
  type: LoadBalancer
  selector: { app: oddball-svc }
  ports: [{ port: 80, targetPort: 80 }]


Apply and verify:

kubectl apply -f oddball-deploy.yaml
kubectl get pods -l app=oddball-svc -o wide
kubectl get svc oddball-svc


When EXTERNAL-IP (ELB DNS) appears, test:

curl http://<elb-hostname>/
# -> Hello, Oddball!

Lifecycle Policy (ECR)

Terraform config creates a lifecycle policy keeping the last 10 images:

Resource: aws_ecr_lifecycle_policy.retain_10

Repository: oddball-svc

Cleanup

Delete app resources (leave infra):

kubectl delete -f oddball-deploy.yaml


Delete the quick nginx demo (if present):

kubectl delete svc hello --ignore-not-found
kubectl delete deploy hello --ignore-not-found


Tear down infra:

terraform destroy

Notes

Provider is pinned to profile = "oddball" and region us-east-2.

EKS warning about inline_policy in the module is known and safe to ignore.

If you ever change VPC subnets/CIDR, destroy EKS first, then apply VPC, then re-apply EKS to avoid dependency cycles.


---

Anything else you want baked into the README (like exact module versions or the `terraform.tfvars` you used)? I can slot that in too.


