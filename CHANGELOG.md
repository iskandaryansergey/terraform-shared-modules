# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `gitlab-runner` module: autoscaling GitLab CI/CD runners on AWS using the
  modern GitLab Runner Autoscaler (`docker-autoscaler` executor + the AWS
  fleeting plugin). A small manager instance drives a Spot fleet of ephemeral,
  single-use EC2 workers that scales to zero when idle. Includes mandatory
  artifact pinning, a runner token held in SSM (never in state on the
  recommended path), unprivileged jobs by default, six CloudWatch alarms, an
  offline TOML structural linter, and dev/production examples.

- Initial project setup with professional documentation.
- Code of Conduct based on Contributor Covenant v2.1.
- Comprehensive Contributing guidelines.
- Security Policy for responsible disclosure.
- MIT License for open-source distribution.

## [1.0.0] - 2026-01-08

### Added

- **Aurora Module** - Production-grade PostgreSQL/MySQL clusters with HA.
- **ECR Module** - Container registry with lifecycle policies and scanning.
- **EKS Module** - Managed Kubernetes with auto-scaling node groups.
- **EFS Module** - Elastic File System with mount targets and lifecycle policies.
- **SQS Module** - Message queuing with DLQ support and encryption.
- **SNS Module** - Pub/sub messaging with comprehensive delivery logging.
- **Network Hub Module** - VPC foundation with security groups and endpoints.

### Features

- Free tier optimized configurations.
- Comprehensive input validation with helpful error messages.
- Consistent tagging strategy across all modules.
- Security-first approach with encryption by default.
- Detailed documentation with usage examples.
- Production-ready defaults with development overrides.

### Security

- KMS encryption enabled by default where applicable.
- Least privilege IAM policies.
- Security groups with restrictive defaults.
- No hardcoded credentials or secrets.
- Comprehensive security scanning integration.

### Documentation

- Module-specific README files with examples.
- Architecture patterns and best practices.
- Troubleshooting guides.
- Cost optimization recommendations.
- Security considerations.

---

## Release Notes Format

### Types of Changes

- **Added** for new features.
- **Changed** for changes in existing functionality.
- **Deprecated** for soon-to-be removed features.
- **Removed** for now removed features.
- **Fixed** for any bug fixes.
- **Security** for vulnerability fixes.

### Version Format

- **MAJOR.MINOR.PATCH** (e.g., 1.2.3)
- **MAJOR** - Breaking changes.
- **MINOR** - New features (backward compatible).
- **PATCH** - Bug fixes (backward compatible).

[Unreleased]: https://github.com/ikovtun/tf-modules/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/ikovtun/tf-modules/releases/tag/v1.0.0
