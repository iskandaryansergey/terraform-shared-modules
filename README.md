# AWS Infrastructure Terraform Modules

[![Terraform Pipeline](https://github.com/ivasik-k7/terraform-shared-modules/actions/workflows/terraform-ci.yaml/badge.svg)](https://github.com/ivasik-k7/terraform-shared-modules/actions/workflows/terraform-ci.yaml)
[![Security Scan](https://img.shields.io/badge/Security-Checkov-brightgreen)](https://www.checkov.io/)
[![Cost Control](https://img.shields.io/badge/Costs-Infracost-blueviolet)](https://www.infracost.io/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Terraform](https://img.shields.io/badge/Terraform-%3E%3D1.5.0-blue)](https://www.terraform.io/)
[![Support](https://img.shields.io/badge/Support-Crypto-orange)](#donations)

Production-grade, enterprise-ready Terraform modules for deploying AWS infrastructure components. Built with security, scalability, and operational excellence as core principles.

## Overview

This repository provides a collection of reusable Terraform modules for common AWS services. Each module is independently deployable, fully tested, and follows AWS best practices. Modules can be composed together to build complete infrastructure solutions.

## Quick Start

### Prerequisites

**Required Tools:**

- **Terraform** `>= 1.3.0` - [Download](https://www.terraform.io/downloads)
- **AWS CLI** `>= 2.0` - [Installation Guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- **Git** - For cloning and version control

**AWS Requirements:**

- **AWS Account** with appropriate service limits
- **IAM User/Role** with programmatic access
- **AWS Provider** `>= 5.0` (auto-installed by Terraform)

### Installation

**1. Install Terraform:**

```bash
# macOS (Homebrew)
brew tap hashicorp/tap
brew install hashicorp/tap/terraform

# Linux (Ubuntu/Debian)
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install terraform

# Verify installation
terraform version
```

**2. Configure AWS Credentials:**

```bash
# Option 1: AWS CLI configuration (recommended)
aws configure
# Enter: Access Key ID, Secret Access Key, Region, Output format

# Option 2: Environment variables
export AWS_ACCESS_KEY_ID="your-access-key"
export AWS_SECRET_ACCESS_KEY="your-secret-key"
export AWS_DEFAULT_REGION="us-east-1"

# Option 3: AWS SSO (for organizations)
aws sso login --profile your-profile

# Verify credentials
aws sts get-caller-identity
```

**3. Clone Repository:**

```bash
git clone https://github.com/ivasik-k7/terraform-shared-modules.git
cd terraform-shared-modules
```

### Basic Usage

**Deploy your first module:**

```hcl
# main.tf
terraform {
  required_version = ">= 1.3.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

module "sqs_queue" {
  source = "./modules/sqs"

  queue_name              = "my-app-queue"
  visibility_timeout      = 30
  message_retention       = 345600  # 4 days
  receive_wait_time       = 20      # Long polling
  enable_dlq              = true
  max_receive_count       = 3

  tags = {
    Environment = "dev"
    Project     = "my-app"
  }
}
```

**Initialize and deploy:**

```bash
# Initialize Terraform (download providers)
terraform init

# Preview changes
terraform plan

# Apply changes
terraform apply

# Destroy resources (when done)
terraform destroy
```

### Quick Examples

Jump to module-specific examples:

- [Aurora Database](./examples/aurora/basic.tf) - PostgreSQL cluster
- [SQS Queue](./examples/sqs/basic.tf) - Message queue with DLQ
- [SNS Topic](./examples/sns/basic.tf) - Pub/sub notifications
- [ECS Service](./examples/ecs/basic.tf) - Fargate nginx
- [Cognito Auth](./examples/cognito/basic.tf) - User authentication
- [API Gateway](./examples/api-gateway/basic.tf) - HTTP API
- [All Examples](./examples/) - Complete list

## Available Modules

### <img src="https://cdn.worldvectorlogo.com/logos/aws-rds.svg" alt="Aurora" height="24"/> [Aurora](./modules/aurora)

Managed relational database with high availability and disaster recovery.

**Key Features:**

- Multi-AZ deployments with automatic failover
- Global database for cross-region replication
- Serverless v2 auto-scaling
- Enhanced monitoring and CloudWatch alarms
- Automated backups with PITR
- KMS encryption at rest

**Use Case:** Production databases requiring HA, read replicas, and compliance

---

### <img src="https://symbols.getvecta.com/stencil_9/0_ec2.e39060729d.svg" alt="ECR" height="24"/> [ECR](./modules/ecr)

Elastic Container Registry for managing Docker container images.

**Key Features:**

- Private repositories with fine-grained access control
- Image lifecycle policies for cost optimization
- Image scanning with vulnerability detection
- Cross-account/cross-region replication
- Registry pull-through cache

**Use Case:** Container image storage and distribution for EKS, ECS workloads

---

### <img src="https://cdn.worldvectorlogo.com/logos/gitlab.svg" alt="GitLab Runner" height="24"/> [GitLab Runner](./modules/gitlab-runner)

Autoscaling GitLab CI/CD runners that cost nothing when idle. A small manager
instance drives a Spot fleet of ephemeral EC2 workers via GitLab's modern
autoscaler (`docker-autoscaler` + the AWS fleeting plugin), scaling from zero to
your ceiling and back.

```hcl
module "runners" {
  source = "./modules/gitlab-runner"

  name              = "ci"
  vpc_id            = var.vpc_id
  worker_subnet_ids = var.private_subnet_ids

  runner_token_ssm_parameter = "/ci/gitlab-runner/token"
  gitlab_runner_version      = "17.9.0-1"
  fleeting_plugin_version    = "1.1.0"

  max_instances = 10
}
```

### <img src="https://cdn.worldvectorlogo.com/logos/aws-ecs.svg" alt="ECS" height="24"/> [ECS](./modules/ecs)

Elastic Container Service for running containerized applications with Fargate or EC2.

**Key Features:**

- Multiple launch types (Fargate, Fargate Spot, EC2)
- Auto-scaling with target tracking and step scaling
- Service discovery with AWS Cloud Map
- Load balancer integration (ALB/NLB)
- EFS volume support for persistent storage
- Container Insights for monitoring
- ECS Exec for interactive debugging

**Use Case:** Containerized applications, microservices, batch processing, web applications

---

### <img src="https://cdn.worldvectorlogo.com/logos/aws-logo.svg" alt="EKS" height="24"/> [EKS](./modules/eks)

Amazon Elastic Kubernetes Service for managed container orchestration.

**Key Features:**

- Managed Kubernetes control plane
- Auto-scaling node groups with Spot instance support
- IAM Roles for Service Accounts (IRSA)
- Built-in cluster addons (VPC CNI, CoreDNS, kube-proxy)
- KMS envelope encryption for etcd
- Advanced networking and security controls

**Use Case:** Microservices orchestration, containerized applications at scale

---

### <img src="https://symbols.getvecta.com/stencil_24/1_amazon-efs.ef56158125.svg" alt="EFS" height="24"/> [EFS](./modules/efs)

Elastic File System for shared NFS storage across EC2 and containers.

**Key Features:**

- Multi-zone file system with automatic failover
- Optional auto-created security group with configurable access
- Lifecycle policies for cost optimization (Standard → IA → Archive)
- Access points for application-specific mounting
- Cross-region replication for disaster recovery
- Automated backup policies
- Support for both multi-zone and one-zone deployments

**Use Case:** Shared storage for containerized applications, NFS mount targets for EKS/EC2

---

### <img src="https://cdn.worldvectorlogo.com/logos/aws-sqs.svg" alt="SQS" height="24"/> [SQS](./modules/sqs)

Simple Queue Service for decoupling microservices and managing distributed message workloads.

**Key Features:**

- **Dual Queue Support:** Provision either **Standard** (best-effort ordering, maximum throughput) or **FIFO** (exactly-once processing, strict ordering) queues.
- **Built-in Dead Letter Queue (DLQ):** Optional automated DLQ creation with configurable `max_receive_count` to isolate and troubleshoot poisonous messages.
- **Cost-Optimized Encryption:** Supports both **SSE-SQS** (free-tier optimized, managed by SQS) and **SSE-KMS** (customer-managed keys) for compliance.
- **Efficiency Controls:** Native support for **Long Polling** (`receive_wait_time_seconds`) to reduce empty receive requests and lower AWS costs.
- **Flexible FIFO Logic:** Configurable `deduplication_scope` and `throughput_limit` (per queue or message group) to scale high-order requirements.
- **Automated Naming:** Intelligently handles the mandatory `.fifo` suffix for both primary and dead-letter queues.
- **Granular Access Control:** Integrated `queue_policy` support for cross-account access and resource-based IAM permissions.

**Use Case:** Decoupling microservices, asynchronous task processing, buffering bursty workloads, and implementing event-driven architectures.

---

### <img src="https://cdn.worldvectorlogo.com/logos/aws-sns.svg" alt="SNS" height="24"/> [SNS](./modules/sns)

Simple Notification Service for pub/sub messaging and mobile notifications.

**Key Features:**

- Standard and FIFO topics
- Delivery status logging
- SMS and Mobile Push support
- Message filtering and fanout patterns
- Encrypted topics

**Use Case:** Event-driven architectures, user notifications, fanout to queues

---

### <img src="https://cdn.worldvectorlogo.com/logos/aws-vpc-1.svg" alt="VPC" height="24"/> [AWS Lending VPC](./modules/aws-lending-vpc)

Migration-factory VPC module. Per-application landing zone VPCs with TGW + VPC endpoints.

**Key Features:**

- 5 subnet tiers (public/private/database/intra/transit) with optional auto-carve from a single CIDR
- Transit Gateway attachment in dedicated transit subnets, with route expansion across multiple route tables
- Region-aware VPC endpoints — pass `"ssm"`, the module adds `com.amazonaws.<region>` for you
- Curated endpoint bundles (`interface_endpoint_services = ["ssm","ssmmessages",...]`)
- Per-AZ NAT (HA) or single NAT (cheap), or skip entirely for central-egress topologies
- Inter-tier SG rule shortcut for the recurring `app -> db` pattern
- Optional FinOps tag enforcement (Project / Team / CostCenter / Owner)
- Plan-time checks for the most common foot-guns (NAT layout, flow log role, DNS resolver AZ count, ...)

**Use Case:** Migration factory landing zones, per-application VPCs lent to workloads with TGW + endpoints providing connectivity

---

### <img src="https://cdn.worldvectorlogo.com/logos/aws-cognito.svg" alt="Cognito" height="24"/> [Cognito](./modules/cognito)

User authentication and authorization service with User Pools and Identity Pools.

**Key Features:**

- User Pools with MFA (TOTP/SMS) and custom attributes
- Identity Pools for federated identities and AWS credentials
- OAuth 2.0 and SAML 2.0 integration
- Lambda triggers for custom authentication flows
- User groups with IAM role mapping
- Advanced security features (risk-based authentication)
- Custom domains and hosted UI

**Use Case:** User authentication, SSO, mobile/web app identity management

---

### <img src="https://cdn.worldvectorlogo.com/logos/aws-api-gateway.svg" alt="API Gateway" height="24"/> [API Gateway](./modules/api-gateway)

Managed API service supporting REST, HTTP, and WebSocket APIs.

**Key Features:**

- REST API (v1) with full feature set (caching, usage plans, request validation)
- HTTP API (v2) with 71% cost savings and lower latency
- WebSocket API for real-time bidirectional communication
- Multiple authorization types (Cognito, JWT, Lambda, IAM)
- Custom domains with ACM certificates
- VPC Link for private integrations
- Usage plans and API keys for rate limiting

**Use Case:** Serverless APIs, microservices gateway, real-time applications

---

### <img src="https://cloud-icons.onemodel.app/aws/Architecture-Service-Icons_01312023/Arch_Networking-Content-Delivery/64/Arch_AWS-Direct-Connect_64@5x.png" alt="Direct Connect" height="24"/> [Direct Connect](./modules/direct-connect)

Dedicated network connection from on-premises to AWS.

**Key Features:**

- Dedicated connections (1 Gbps, 10 Gbps, 100 Gbps)
- Link Aggregation Groups (LAG) for redundancy
- Private, public, and transit virtual interfaces
- Direct Connect Gateway for multi-region connectivity
- MACsec encryption support
- Cross-account gateway associations

**Use Case:** Hybrid cloud connectivity, low-latency workloads, data migration

---

### <img src="https://cdn.worldvectorlogo.com/logos/aws-route53.svg" alt="Route53" height="24"/> [Route53](./modules/route53)

Scalable DNS and domain name management service.

**Key Features:**

- Public and private hosted zones
- Multiple routing policies (simple, weighted, latency, failover, geolocation)
- Health checks with CloudWatch alarms
- DNSSEC for domain security
- Traffic flow for complex routing
- Domain registration

**Use Case:** DNS management, traffic routing, health monitoring, multi-region failover

---

### <img src="https://cdn.worldvectorlogo.com/logos/terraform-enterprise.svg" alt="Terraform" height="24"/> [TFE Hub](./modules/tfe-hub)

Terraform Enterprise/Cloud workspace and organization management.

**Key Features:**

- Workspace creation and configuration
- VCS integration (GitHub, GitLab, Bitbucket)
- Variable sets and workspace variables
- Team access management
- Run triggers and notifications
- Sentinel policy enforcement

**Use Case:** Terraform Cloud/Enterprise automation, workspace management, CI/CD integration

---

#### Free Tier Tip 💡

To stay under the **1 Million Free Requests** per month, this module is optimized to use **Long Polling (20s)** and **SQS-Managed Encryption**. This combination provides maximum power and security without consuming KMS budget or inflating API request counts.

---

### 🗺️ Planned Modules

- **S3** - Object storage with lifecycle policies and replication
- **CloudFront** - Global CDN with WAF integration
- **Lambda** - Serverless compute with event triggers
- **DynamoDB** - NoSQL database with global tables
- **Secrets Manager** - Credential and secret management
- **WAF** - Web Application Firewall for CloudFront and ALB

## Architecture Patterns

### Composition Model

Modules are designed to be independently useful while supporting composition:

```hcl
# Deploy complete application stack
module "aurora" {
  source = "./aurora"
  # configuration...
}

module "eks" {
  source = "./eks"
  # configuration...
}

module "ecr" {
  source = "./ecr"
  # configuration...
}
```

### Best Practices Implemented

Each module enforces:

✅ **Encryption** - All data at rest encrypted with AWS KMS  
✅ **Least Privilege** - IAM roles and security groups follow principle of least privilege  
✅ **High Availability** - Multi-AZ deployment where applicable  
✅ **Observability** - CloudWatch monitoring, logging, and alarms included  
✅ **Backup & Recovery** - Automated backups with retention policies  
✅ **Versioning** - Explicit provider and resource versioning  
✅ **Tagging Strategy** - Consistent tagging across all resources

## Security Considerations

### Credential Management

- **Never commit secrets** to version control
- Use Terraform variables marked as `sensitive = true`
- Store sensitive values in AWS Secrets Manager or environment variables
- Use AWS SSO or federated authentication

### Network Security

- Deploy resources in private subnets by default
- Use security groups for inbound/outbound rules
- Enable VPC Flow Logs for network monitoring
- Implement network ACLs for additional isolation

### Access Control

- Use IAM roles with minimum required permissions
- Enable MFA for AWS console access
- Audit IAM policies regularly
- Use resource-based policies where applicable

### Data Protection

- Enable encryption at rest (KMS) for all services
- Use encryption in transit (TLS/SSL)
- Enable versioning for stateful resources
- Implement automated backup strategies

## Module Documentation

Each module includes:

- Detailed `README.md` with examples
- Input variables with descriptions and validations
- Output values for resource information
- Required AWS permissions
- Troubleshooting guidance

See individual module directories for complete documentation.

## Contributing

### Development Workflow

1. Create a feature branch: `git checkout -b feature/module-improvement`
2. Make changes following Terraform conventions
3. Run `terraform fmt -recursive` to format code
4. Test module configuration locally
5. Submit pull request with description

### Code Standards

- Use `terraform fmt` for consistent formatting
- Include descriptive variable and output names
- Add validation rules for critical inputs
- Document non-obvious configurations
- Include helpful error messages in validations

### Testing

Before submitting changes:

- Run `terraform validate` on all modules
- Check for syntax errors with `terraform fmt -check`
- Review security implications
- Test with sample `tfvars` configurations

## Troubleshooting

### Common Issues

**"Provider version not available"**

- Run `terraform init -upgrade` to fetch latest compatible version
- Check [AWS Provider Changelog](https://github.com/hashicorp/terraform-provider-aws/releases)

**"AWS credentials not found"**

- Verify AWS credentials: `aws sts get-caller-identity`
- Check environment variables: `$AWS_ACCESS_KEY_ID`, `$AWS_SECRET_ACCESS_KEY`
- Confirm IAM permissions for required services

**"Resource already exists"**

- Check current infrastructure: `terraform state list`
- Use `terraform import` to manage existing resources
- Review AWS Console for unmanaged resources

For module-specific issues, see the module's README file.

## Support

### Getting Help

- Review module-specific documentation in each directory
- Check AWS service documentation links in module comments
- Examine Terraform AWS Provider documentation
- Open an issue for bugs or feature requests

### Reporting Issues

Include:

- Module name and version
- Error message and logs
- Configuration snippet (without secrets)
- Expected vs. actual behavior

## Roadmap

- [x] Aurora DB module with full HA and monitoring
- [x] ECR module with image scanning and replication
- [x] ECS module with Fargate and EC2 launch types
- [x] EKS module with managed node groups
- [x] EFS module with mount targets and lifecycle policies
- [x] SQS module with FIFO support and DLQ
- [x] SNS module with filtering and delivery logging
- [x] Network Hub module for foundational infrastructure
- [x] Cognito module with User Pools and Identity Pools
- [x] API Gateway module (REST, HTTP, WebSocket)
- [x] Direct Connect module with LAG and virtual interfaces
- [x] Route53 module for DNS management
- [x] TFE Hub module for Terraform Cloud/Enterprise
- [ ] S3 module with lifecycle and replication policies
- [ ] CloudFront distribution with WAF integration
- [ ] Lambda module with event sources and layers
- [ ] DynamoDB module with global tables
- [ ] Secrets Manager module for credential management
- [ ] Monitoring module with centralized alerting
- [ ] Cost optimization configurations and examples

## License

This project is provided as-is for infrastructure management. Review licensing terms before use in commercial environments.

## Maintenance

Modules are maintained to support:

- Latest Terraform versions
- AWS provider updates (typically within 30 days of release)
- Security patches and vulnerability fixes
- AWS service deprecations and new features

Regular updates recommended to benefit from:

- Enhanced security controls
- Performance optimizations
- New AWS service capabilities
- Bug fixes and stability improvements

---

**Last Updated:** January 2026  
**Terraform Version:** 1.3+  
**AWS Provider Version:** 5.0+
