# Oddball Demo Environment

This repository demonstrates an end-to-end DevSecOps style environment with:

- **Terraform** for AWS EKS cluster provisioning (`oddball-iac/`)
- **Ansible** for configuration management (`ansible/`)
- **Helm** for Kubernetes manifests (`chart/`)
- **Docker + Compose** for local service builds and validation (`app/`, `docker-compose.yml`)
- **GitHub Actions** for CI/CD (`.github/workflows/`)

---

## Local Development

### Requirements
- Docker Desktop with WSL2 integration
- Docker Compose v2+
- jq (for pretty-printing responses)

### Start the stack

```bash
docker compose up -d --build

