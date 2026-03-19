# Getting Started — `terraform-deploy` (Central Pipeline)

Welcome to the **centralized Terraform deployment pipeline** maintained by the Platform Engineering team. This repository contains the reusable GitHub Actions workflows and composite actions that power all Terraform-based infrastructure deployments across the organization.

---

## Table of Contents

1. [What's in This Repo](#whats-in-this-repo)
2. [Architecture Overview](#architecture-overview)
3. [Prerequisites](#prerequisites)
4. [Onboarding a New Application Team](#onboarding-a-new-application-team)
5. [GitHub Secrets & Environments Setup](#github-secrets--environments-setup)
6. [Azure OIDC Configuration](#azure-oidc-configuration)
7. [Terraform State Backend](#terraform-state-backend)
8. [Pipeline Inputs Reference](#pipeline-inputs-reference)
9. [Workflows Reference](#workflows-reference)
10. [Composite Actions Reference](#composite-actions-reference)
11. [Troubleshooting](#troubleshooting)
12. [Contributing](#contributing)

---

## What's in This Repo

```
terraform-deploy/
├── .github/
│   ├── workflows/
│   │   ├── central-terraform.yml    # Main reusable workflow (called by app teams)
│   │   ├── drift-detection.yml      # Nightly drift detection across environments
│   │   └── feature-cleanup.yml      # Weekly orphaned feature-branch cleanup
│   └── actions/
│       ├── setup-terraform/         # Composite: install & pin Terraform version
│       ├── terraform-plan/          # Composite: plan + JSON export
│       ├── terraform-apply/         # Composite: apply saved plan or destroy
│       └── checkov-scan/            # Composite: Checkov + SARIF upload
├── state-backend/                   # Terraform module to bootstrap state storage
│   ├── main.tf                      # Storage account, containers, RBAC
│   ├── backend.hcl                  # Self-referencing backend config
│   ├── terraform.tfvars.example     # Example variable values
│   └── .terraform-version           # Pinned Terraform version
├── scripts/
│   └── setup-oidc-identities.sh     # Create split Plan/Apply OIDC identities
├── .tflint.hcl                      # TFLint configuration (Azure ruleset)
├── CODEOWNERS                       # Platform team owns all files
├── GETTING_STARTED.md               # ← You are here
└── README.md
```

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│  App Team Repo (.github/workflows/infra-deploy.yml)             │
│  ─ triggers on push / PR to main, DEV, UAT, feature/**         │
│  ─ calls central pipeline via  jobs.<id>.uses:                  │
└────────────────────────┬────────────────────────────────────────┘
                         │  workflow_call (with inputs + secrets)
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│  terraform-deploy (this repo)                                    │
│  .github/workflows/central-terraform.yml                         │
│                                                                   │
│  ┌──────────────────────┐    ┌──────────────────────────────┐   │
│  │  Job 1: Plan          │───▶│  Job 2: Apply                │   │
│  │  • checkout (caller)  │    │  • download plan artifact    │   │
│  │  • terraform init     │    │  • terraform apply tfplan    │   │
│  │  • fmt / validate     │    │  OR                          │   │
│  │  • TFLint             │    │  • terraform destroy         │   │
│  │  • terraform plan     │    │    (feature branch cleanup)  │   │
│  │  • Checkov scan       │    └──────────────────────────────┘   │
│  │  • Infracost          │                                        │
│  │  • upload artifact    │         ▲  requires plan job           │
│  └──────────────────────┘         │  + environment approval      │
│                                    │  (for Production)            │
└────────────────────────────────────┘──────────────────────────────┘
```

**Key design decisions:**
- **Two-job architecture** — Plan uploads a `tfplan` binary artifact; Apply downloads and applies that exact plan. This guarantees what was reviewed = what gets deployed.
- **Split-identity security model** — Plan job uses a **read-only** OIDC identity; Apply job uses a **scoped-write** identity. No single credential has broad privileges (see [Credential Model](#credential-model--least-privilege) below).
- **OIDC authentication** — No long-lived Azure credentials. Uses `azure/login@v2` with Workload Identity Federation.
- **Concurrency control** — Scoped per environment + branch. Never cancels a run mid-apply.
- **Checkov** is the single security/policy scanner (replaces deprecated tfsec).
- **Infracost** posts cost estimates on PRs.

---

## Prerequisites

Before application teams can use this pipeline, the **Platform Engineering team** must set up:

### 1. Azure AD OIDC Identities (Split Plan/Apply)

The pipeline uses **two separate identities per environment** — a read-only Plan identity and a scoped-write Apply identity. This minimises blast radius and satisfies least-privilege requirements.

Use the provided automation script to create both identities, federated credentials, and RBAC assignments in one step:

**Linux / macOS (bash):**
```bash
# From the terraform-deploy repo root:
chmod +x scripts/setup-oidc-identities.sh

./scripts/setup-oidc-identities.sh \
  --org myorg \
  --repo app-team-repo \
  --env Production \
  --subscription <PROD_SUB_ID> \
  --target-rg rg-myapp-prod \
  --state-rg rg-terraform-state \
  --state-account stterraformstateorg \
  --state-container my-team
```

**Windows (PowerShell):**
```powershell
# From the terraform-deploy repo root:
.\scripts\setup-oidc-identities.ps1 `
  -Org myorg `
  -Repo app-team-repo `
  -Env Production `
  -Subscription "<PROD_SUB_ID>" `
  -TargetRG rg-myapp-prod `
  -StateRG rg-terraform-state `
  -StateAccount stterraformstateorg `
  -StateContainer my-team
```

Repeat for each environment (Dev, UAT, Sandbox). The script outputs the Client IDs to store as GitHub secrets.

> **Note:** With reusable workflows (`workflow_call`), the OIDC `sub` claim contains the **calling repo**, not this central repo. Federated credentials must match calling repo patterns (e.g. `repo:myorg/app-*:environment:Production`).

### 2. Terraform State Storage Account

The state backend is managed via Terraform itself — see `state-backend/`:

```bash
cd state-backend/

# Copy and edit the example variables
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — set storage_account_name, team_containers, etc.

# First-time bootstrap (local state)
terraform init
terraform plan
terraform apply

# After creation, migrate state into itself for self-management:
terraform init -backend-config="backend.hcl" -migrate-state
```

This creates:
- A geo-redundant storage account with blob versioning and soft-delete
- A private blob container per application team
- The RBAC assignments are handled by the `setup-oidc-identities.sh` script (per identity, per container)

> **Important:** The state storage account has `public_network_access_enabled = true` for Iteration 1 (GitHub-hosted runners). Restrict this when migrating to self-hosted runners with VNet integration.

### 3. Azure Subscriptions / Resource Groups

Create or designate:
- A **Dev** subscription or resource group
- A **UAT** subscription or resource group
- A **Production** subscription or resource group
- Optionally a **Sandbox** subscription for feature-branch environments

### 4. Infracost API Key

Sign up at [infracost.io](https://www.infracost.io/) and obtain an API key.

---

## Onboarding a New Application Team

1. **Create a new repo** from the `app-team-repo` template (or copy the golden-path structure).
2. **Add the team's state container** — update `state-backend/terraform.tfvars` and re-apply:
   ```hcl
   team_containers = ["default", "platform-engineering", "new-team"]
   ```
3. **Create split OIDC identities** for each environment (Dev, UAT, Production, Sandbox):

   **Linux / macOS:**
   ```bash
   ./scripts/setup-oidc-identities.sh \
     --org myorg --repo new-team-repo --env Dev \
     --subscription <DEV_SUB_ID> --target-rg rg-newteam-dev \
     --state-rg rg-terraform-state --state-account stterraformstateorg \
     --state-container new-team
   ```

   **Windows:**
   ```powershell
   .\scripts\setup-oidc-identities.ps1 `
     -Org myorg -Repo new-team-repo -Env Dev `
     -Subscription "<DEV_SUB_ID>" -TargetRG rg-newteam-dev `
     -StateRG rg-terraform-state -StateAccount stterraformstateorg `
     -StateContainer new-team
   ```
   Repeat for UAT, Production, Sandbox.
4. **Configure GitHub Environments** in the new repo with the secrets output by the script (see table below).
5. **Update the caller workflow** in the repo to set the correct `team_name` input.
6. **Push to DEV branch** and watch the pipeline run!

---

## GitHub Secrets & Environments Setup

In **each application team's repository**, create GitHub Environments with the following secrets:

| Environment   | Secret                       | Description                                        |
|---------------|------------------------------|----------------------------------------------------||
| Dev           | `AZURE_CLIENT_ID_PLAN`      | Plan identity Client ID (**read-only**)             |
| Dev           | `AZURE_CLIENT_ID_APPLY`     | Apply identity Client ID (**scoped-write**)         |
| Dev           | `AZURE_TENANT_ID`           | Azure AD Tenant ID                                  |
| Dev           | `AZURE_SUBSCRIPTION_ID`     | Dev subscription ID                                 |
| Dev           | `TF_BACKEND_STORAGE_ACCOUNT`| State storage account name                          |
| Dev           | `TF_BACKEND_RESOURCE_GROUP` | State storage resource group name                   |
| Dev           | `INFRACOST_API_KEY`         | Infracost API key                                   |
| UAT           | _(same keys, UAT values)_   |                                                     |
| Production    | _(same keys, Prod values)_  | + **Required reviewers** protection rule            |
| Sandbox       | _(same keys, Sandbox values)_|                                                    |

> **Production environment** should have **required reviewers** enabled (GitHub Environment protection rule). This inserts a manual approval gate before `terraform apply` runs against production.

---

## Azure OIDC Configuration

The pipeline uses **Workload Identity Federation** — no client secrets stored in GitHub.

### How it works

1. GitHub Actions requests an OIDC token from GitHub's token service.
2. The token's `sub` claim identifies the calling repo + environment: `repo:myorg/app-team-repo:environment:Production`
3. Azure AD validates the token against the federated credential and issues an access token.
4. `azure/login@v2` uses the access token — no secrets involved.

### Credential Model — Least Privilege

The pipeline uses **two separate OIDC identities** to enforce least privilege:

```
┌───────────────────────────────────────────────────────────┐
│  Plan Identity (AZURE_CLIENT_ID_PLAN)                      │
│  ├─ Reader on target resource group                       │
│  ├─ Storage Blob Data Reader on state container           │
│  └─ CANNOT create/modify/delete any resources             │
│                                                            │
│  Attack surface: read-only. Even if compromised, an       │
│  attacker cannot alter infrastructure or state.            │
└───────────────────────────────────────────────────────────┘

┌───────────────────────────────────────────────────────────┐
│  Apply Identity (AZURE_CLIENT_ID_APPLY)                    │
│  ├─ Contributor on target resource group ONLY             │
│  ├─ Storage Blob Data Contributor on state container      │
│  └─ CANNOT access other teams' RGs or state               │
│                                                            │
│  Attack surface: scoped to one RG + one state container.  │
│  Cannot modify other teams' infrastructure.                │
└───────────────────────────────────────────────────────────┘
```

**Why two identities?**
- The Plan job runs on every push/PR and is the most exposed step. Limiting it to read-only means a supply-chain attack on a linter or scanner dependency cannot escalate to resource modification.
- The Apply job only runs after plan review + approval. Its credential is scoped to a single resource group — not subscription-wide Contributor.
- Each team gets its own pair of identities per environment, so a compromise in one team cannot affect another.

### Federated Credential Subject Patterns

| Environment | Subject Claim                                          |
|-------------|--------------------------------------------------------|
| Dev         | `repo:myorg/<repo>:environment:Dev`                   |
| UAT         | `repo:myorg/<repo>:environment:UAT`                   |
| Production  | `repo:myorg/<repo>:environment:Production`            |
| Sandbox     | `repo:myorg/<repo>:environment:Sandbox`               |

You can use wildcard patterns: `repo:myorg/app-*:environment:Dev` to cover all app team repos with a single credential. However, for maximum isolation, use **per-repo identities** (the `setup-oidc-identities.sh` script creates these automatically).

---

## Terraform State Backend

The pipeline dynamically configures the Terraform backend at `init` time:

```
terraform init \
  -backend-config="storage_account_name=stterraformstateorg" \
  -backend-config="container_name=<team_name>"     # from workflow input
  -backend-config="key=<env_name>.tfstate"          # from workflow input
  -backend-config="resource_group_name=rg-terraform-state"
```

**State isolation:** Each environment gets its own `.tfstate` file (`Dev.tfstate`, `UAT.tfstate`, `Production.tfstate`, `feature-xyz.tfstate`).

**State locking:** Azure Storage blob leases provide built-in locking — no additional configuration needed.

---

## Pipeline Inputs Reference

| Input               | Type    | Required | Default   | Description                                          |
|---------------------|---------|----------|-----------|------------------------------------------------------|
| `env_name`          | string  | **yes**  | —         | GitHub Environment name (Dev, UAT, Production, etc.) |
| `tf_working_dir`    | string  | no       | `infra`   | Path to Terraform root module in calling repo        |
| `terraform_version` | string  | no       | `""`      | Explicit version; falls back to `.terraform-version` |
| `destroy`           | boolean | no       | `false`   | Run `terraform destroy` instead of apply             |
| `plan_only`         | boolean | no       | `false`   | Skip the Apply job entirely                          |
| `team_name`         | string  | no       | `default` | Team identifier for state backend container          |

---

## Workflows Reference

### `central-terraform.yml` — Main Pipeline

The core reusable workflow. Called by app teams via `jobs.<id>.uses:`.

**Jobs:**
1. **Plan** — checkout, init, fmt, validate, TFLint, plan, Checkov, Infracost, upload artifact
2. **Apply** — download plan artifact, apply (or destroy)

### `drift-detection.yml` — Nightly Drift Check

Runs `terraform plan` against persistent environments (Dev, UAT, Production) on a cron schedule. Creates a GitHub Issue if drift is detected.

### `feature-cleanup.yml` — Weekly Orphan Cleanup

Scans Azure for resource groups matching the feature-branch naming pattern and destroys any older than 7 days whose branch no longer exists. Safety net for the primary PR-closed cleanup trigger.

---

## Composite Actions Reference

| Action               | Purpose                                                  |
|----------------------|----------------------------------------------------------|
| `setup-terraform`    | Resolve and install pinned Terraform version             |
| `terraform-plan`     | Run `terraform plan`, export JSON for downstream tools   |
| `terraform-apply`    | Apply saved plan artifact or run destroy                 |
| `checkov-scan`       | Run Checkov against plan JSON, upload SARIF              |

---

## Troubleshooting

### "OIDC token audience is not valid"
Ensure the federated credential's `audiences` includes `api://AzureADTokenExchange`.

### "No changes. Your infrastructure matches the configuration."
Plan exit code `0` — the Apply job correctly skips (there's nothing to apply).

### Checkov fails with "no valid plan file"
Ensure `terraform show -json tfplan > tfplan.json` succeeded. Check that the Terraform version in `.terraform-version` matches what's installed.

### Apply job doesn't run
Check that: (1) Plan exit code was `2` (changes present), (2) `plan_only` is not `true`, (3) the GitHub Environment approval (if required) has been granted.

### "Error acquiring the state lock"
Another pipeline run (or manual session) has the state locked. Wait for it to complete or use `terraform force-unlock <LOCK_ID>` carefully.

---

## Contributing

This repository is owned by the **Platform Engineering team**. All changes require:
- A pull request with at least one approval from `@myorg/platform-engineering`
- All CI checks passing
- No direct pushes to `main`

To propose a change:
1. Create a feature branch from `main`
2. Make your changes
3. Open a PR and request review from the platform team
4. After approval + merge, tag a new release (e.g. `v1.1.0`)
5. Communicate the new version to app teams for adoption

### Versioning

App teams pin to a **semantic version tag** (e.g. `@v1.0.0`). Follow semver:
- **Patch** (`v1.0.1`): Bug fixes, no input changes
- **Minor** (`v1.1.0`): New optional inputs, backwards-compatible
- **Major** (`v2.0.0`): Breaking changes to inputs or behavior

> Never push breaking changes to an existing tag. Always create a new major version.
