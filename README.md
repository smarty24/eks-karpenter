# EKS Cluster with Karpenter

This repository contains Terraform code to deploy an EKS cluster with Karpenter for advanced node provisioning, supporting both x86 (AMD64) and ARM64 (Graviton) instances.

## Prerequisites

- AWS CLI configured with appropriate credentials
- Terraform >= 1.0
- kubectl

## Network Architecture

The infrastructure includes:
- VPC with CIDR 10.0.0.0/16 (configurable)
- 3 private subnets (one per AZ) for workload nodes
- 3 public subnets (one per AZ) for load balancers
- NAT Gateway for private subnet internet access
- Proper tagging for EKS and Karpenter

## Quick Start

1. Clone this repository:
```bash
git clone <repository-url>
cd eks-karpenter
```

2. Create a `terraform.tfvars` file:
```hcl
region       = "eu-west-1"  # or your preferred region
cluster_name = "my-eks-cluster"
vpc_cidr     = "10.200.0.0/16"  # optional, this is the default
```

3. Initialize and apply Terraform:
```bash
terraform init
terraform plan -var-file=environment/dev-config.tfvars # duplicate this file to create config for staging or prod
terraform apply -var-file=environment/dev-config.tfvars # duplicate this file to create config for staging or prod

```

4. Configure kubectl:
```bash
aws eks update-kubeconfig --region <region> --name <cluster-name>
```

## Running Workloads on Specific Architectures

### Deploy on x86 (AMD64)
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-x86
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nginx-x86
  template:
    metadata:
      labels:
        app: nginx-x86
    spec:
      nodeSelector:
        kubernetes.io/arch: amd64
      containers:
      - name: nginx
        image: nginx:latest
```

### Deploy on ARM64 (Graviton)
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-arm
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nginx-arm
  template:
    metadata:
      labels:
        app: nginx-arm
    spec:
      nodeSelector:
        kubernetes.io/arch: arm64
      containers:
      - name: nginx
        image: nginx:latest
```

### Deploy with Cost Optimization (Spot Instances)
Add the following to your pod spec to prefer Spot instances:
```yaml
nodeSelector:
  kubernetes.io/arch: arm64  # or amd64
  karpenter.sh/capacity-type: spot
```

## Monitoring Node Provisioning

Check Karpenter provisioner status:
```bash
kubectl get provisioners
```

View provisioned nodes:
```bash
kubectl get nodes -L kubernetes.io/arch,node.kubernetes.io/instance-type
```

## Network Verification

Verify VPC and subnet setup:
```bash
aws ec2 describe-vpcs --filters "Name=tag:Name,Values=my-eks-cluster-vpc"
aws ec2 describe-subnets --filters "Name=vpc-id,Values=<vpc-id>"
```

## Clean Up

To destroy the infrastructure:
```bash
terraform destroy
```

Note: Ensure all workloads are removed before destroying the infrastructure to avoid any issues with node termination.

## Architecture Details

This setup includes:
- EKS 1.31 cluster
- VPC with private/public subnets
- Karpenter for node provisioning
- Support for both x86 and ARM64 architectures
- Spot and On-Demand instance support
- Automatic node scaling based on workload demands
- Node termination after 30 seconds of being empty

## Cost Optimization Tips

1. Use ARM64 instances where possible (15-40% cost savings)
2. Leverage Spot instances for non-critical workloads
3. Enable automatic scaling down of empty nodes
4. Use appropriate instance sizes for your workloads
5. Single NAT Gateway to reduce costs (consider one per AZ for production)

## Troubleshooting

If nodes aren't being provisioned:
1. Check Karpenter logs:
```bash
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter -c controller
```

2. Verify provisioner configuration:
```bash
kubectl describe provisioners
```

3. Check pod events:
```bash
kubectl describe pod <pod-name>
```

4. Verify subnet tagging:
```bash
aws ec2 describe-subnets --filters "Name=tag:karpenter.sh/discovery,Values=my-eks-cluster"
```
