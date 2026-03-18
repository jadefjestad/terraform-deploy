# terraform-deploy — Centralized Terraform CI/CD Pipeline

> Maintained by the **Platform Engineering** team

A centralized, reusable GitHub Actions pipeline for Terraform deployments to Azure. Application teams call this pipeline from their own repositories — no need to write deployment logic from scratch.

## Key Features

- **Reusable workflow** — single `workflow_call` entry point for all Terraform deployments
- **Two-job architecture** — Plan uploads artifact → Apply uses the exact reviewed plan
- **OIDC authentication** — Workload Identity Federation, no stored secrets
- **Quality gates** — TFLint, Checkov, `terraform fmt/validate`, Infracost cost estimation
- **Multi-environment** — DEV, UAT, Production + ephemeral feature-branch environments
- **Drift detection** — Nightly cron checks for out-of-band changes
- **Cleanup automation** — PR-closed triggers + weekly cron destroy orphaned resources

## Quick Start

See **[GETTING_STARTED.md](GETTING_STARTED.md)** for full setup instructions.

**For app teams:** Use the [app-team-repo](https://github.com/myorg/app-team-repo) template to get started in minutes.

## Repository Structure

```
.github/
├── workflows/
│   ├── central-terraform.yml   # Main reusable pipeline
│   ├── drift-detection.yml     # Nightly drift detection
│   └── feature-cleanup.yml     # Weekly orphan cleanup
└── actions/
    ├── setup-terraform/        # Pin & install Terraform
    ├── terraform-plan/         # Plan + JSON export
    ├── terraform-apply/        # Apply saved plan or destroy
    └── checkov-scan/           # Security scan + SARIF upload
scripts/
└── setup-oidc-identities.sh    # Automate Plan + Apply OIDC identity creation
state-backend/
├── main.tf                     # Terraform module for shared state storage
├── backend.hcl                 # Self-referencing backend config
├── terraform.tfvars.example    # Example variable values
└── .terraform-version          # Pinned Terraform version
```

## Security — Split-Credential Model

The pipeline uses **two separate OIDC identities** per environment to enforce least privilege:

| Identity | Secret | Permissions |
|----------|--------|-------------|
| **Plan** | `AZURE_CLIENT_ID_PLAN` | Reader on target RG + Storage Blob Data Reader (read-only) |
| **Apply** | `AZURE_CLIENT_ID_APPLY` | Contributor scoped to target RG + Storage Blob Data Contributor |

Run `scripts/setup-oidc-identities.sh` to create both identities for a new team/repo. See [GETTING_STARTED.md](GETTING_STARTED.md) for details.

## State Backend

The `state-backend/` directory contains a self-managed Terraform module that provisions the shared state storage account (GRS replication, blob versioning, 30-day soft-delete, per-team containers). Bootstrap it once, then manage it via its own Terraform state.

## Usage

In your app repo's workflow file:

```yaml
jobs:
  deploy:
    uses: myorg/terraform-deploy/.github/workflows/central-terraform.yml@v1.0.0
    with:
      env_name: Dev
      tf_working_dir: infra
      team_name: my-team
    secrets: inherit
```

## License

Internal use only — © Platform Engineering