<#
.SYNOPSIS
  Creates SEPARATE Azure AD App Registrations for Plan (read-only) and
  Apply (scoped-write) per environment, following least-privilege principles.

.DESCRIPTION
  Identity Model:

    Plan Identity (read-only)
    - Reader on target subscription/RG
    - Storage Blob Data Reader on state container
    - CANNOT create, modify, or delete any Azure resources
    Used by: Plan job (lint, validate, plan, Checkov, Infracost)

    Apply Identity (scoped-write)
    - Contributor scoped to TARGET resource group only (not sub-wide)
    - Storage Blob Data Contributor on state container
    - CANNOT access other teams' resource groups or state
    Used by: Apply job (terraform apply / destroy)

.EXAMPLE
  .\setup-oidc-identities.ps1 `
    -Org myorg `
    -Repo app-team-repo `
    -Env Production `
    -Subscription "<SUB_ID>" `
    -TargetRG rg-myapp-prod `
    -StateRG rg-terraform-state `
    -StateAccount stterraformstateorg `
    -StateContainer my-team
#>

param(
    [Parameter(Mandatory)] [string] $Org,
    [Parameter(Mandatory)] [string] $Repo,
    [Parameter(Mandatory)] [string] $Env,
    [Parameter(Mandatory)] [string] $Subscription,
    [Parameter(Mandatory)] [string] $TargetRG,
    [Parameter(Mandatory)] [string] $StateRG,
    [Parameter(Mandatory)] [string] $StateAccount,
    [Parameter(Mandatory)] [string] $StateContainer
)

$ErrorActionPreference = 'Stop'

Write-Host "======================================================================"
Write-Host "  Setting up OIDC identities for: $Org/$Repo -- $Env"
Write-Host "======================================================================"

# ── 1. Create Plan Identity (read-only) ─────────────────────────────────────
$planAppName = "oidc-$Repo-$Env-plan"
Write-Host ""
Write-Host "> Creating Plan identity: $planAppName"

$planAppId = az ad app create --display-name $planAppName --query appId -o tsv
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create Plan app registration."; exit 1 }

$planObjId = az ad app show --id $planAppId --query id -o tsv
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to retrieve Plan app object ID."; exit 1 }

# Create service principal (may already exist — ignore error if so)
$ErrorActionPreference = 'Continue'
az ad sp create --id $planAppId --only-show-errors 2>&1 | Out-Null
$ErrorActionPreference = 'Stop'
$planSpId = az ad sp show --id $planAppId --query id -o tsv
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to retrieve Plan service principal ID."; exit 1 }

Write-Host "  App ID:  $planAppId"
Write-Host "  SP ID:   $planSpId"

# ── 2. Create Apply Identity (scoped-write) ──────────────────────────────────
$applyAppName = "oidc-$Repo-$Env-apply"
Write-Host ""
Write-Host "> Creating Apply identity: $applyAppName"

$applyAppId = az ad app create --display-name $applyAppName --query appId -o tsv
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create Apply app registration."; exit 1 }

$applyObjId = az ad app show --id $applyAppId --query id -o tsv
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to retrieve Apply app object ID."; exit 1 }

# Create service principal (may already exist — ignore error if so)
$ErrorActionPreference = 'Continue'
az ad sp create --id $applyAppId --only-show-errors 2>&1 | Out-Null
$ErrorActionPreference = 'Stop'
$applySpId = az ad sp show --id $applyAppId --query id -o tsv
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to retrieve Apply service principal ID."; exit 1 }

Write-Host "  App ID:  $applyAppId"
Write-Host "  SP ID:   $applySpId"

# ── 3. Add OIDC Federated Credentials ────────────────────────────────────────
$issuer   = "https://token.actions.githubusercontent.com"
$audience = "api://AzureADTokenExchange"
$subject  = "repo:${Org}/${Repo}:environment:${Env}"

Write-Host ""
Write-Host "> Adding federated credentials (subject: $subject)"

# Write JSON to temp files to avoid PowerShell quote-stripping issues with az cli
$planFedCredFile = Join-Path $env:TEMP "plan_fed_cred.json"
@{
    name        = "github-$Env-plan"
    issuer      = $issuer
    subject     = $subject
    audiences   = @($audience)
    description = "Read-only Plan identity for $Repo $Env"
} | ConvertTo-Json | Set-Content -Path $planFedCredFile -Encoding utf8

az ad app federated-credential create --id $planObjId --parameters "@$planFedCredFile" --only-show-errors | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Warning "Plan federated credential may already exist (or failed). Continuing..." }
Remove-Item $planFedCredFile -ErrorAction SilentlyContinue

$applyFedCredFile = Join-Path $env:TEMP "apply_fed_cred.json"
@{
    name        = "github-$Env-apply"
    issuer      = $issuer
    subject     = $subject
    audiences   = @($audience)
    description = "Scoped-write Apply identity for $Repo $Env"
} | ConvertTo-Json | Set-Content -Path $applyFedCredFile -Encoding utf8

az ad app federated-credential create --id $applyObjId --parameters "@$applyFedCredFile" --only-show-errors | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Warning "Apply federated credential may already exist (or failed). Continuing..." }
Remove-Item $applyFedCredFile -ErrorAction SilentlyContinue

Write-Host "  Federated credentials created"

# ── 4. Assign RBAC Roles ─────────────────────────────────────────────────────
Write-Host ""
Write-Host "> Assigning RBAC roles..."

$targetRgScope       = "/subscriptions/$Subscription/resourceGroups/$TargetRG"
$stateAccountScope   = "/subscriptions/$Subscription/resourceGroups/$StateRG/providers/Microsoft.Storage/storageAccounts/$StateAccount"
$stateContainerScope = "$stateAccountScope/blobServices/default/containers/$StateContainer"

# Temporarily allow errors so RBAC failures don't abort the script
$ErrorActionPreference = 'Continue'

# Plan Identity Roles (READ-ONLY)
Write-Host "  Plan identity -> Reader on target RG"
az role assignment create `
    --role "Reader" `
    --assignee-object-id $planSpId `
    --assignee-principal-type ServicePrincipal `
    --scope $targetRgScope `
    --only-show-errors 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Warning "Role assignment failed - check that RG '$TargetRG' exists." }

Write-Host "  Plan identity -> Storage Blob Data Reader on state container"
az role assignment create `
    --role "Storage Blob Data Reader" `
    --assignee-object-id $planSpId `
    --assignee-principal-type ServicePrincipal `
    --scope $stateContainerScope `
    --only-show-errors 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Warning "Role assignment failed - check that storage account '$StateAccount' and container '$StateContainer' exist." }

# Apply Identity Roles (SCOPED WRITE)
Write-Host "  Apply identity -> Contributor on target RG (scoped)"
az role assignment create `
    --role "Contributor" `
    --assignee-object-id $applySpId `
    --assignee-principal-type ServicePrincipal `
    --scope $targetRgScope `
    --only-show-errors 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Warning "Role assignment failed - check that RG '$TargetRG' exists." }

Write-Host "  Apply identity -> Storage Blob Data Contributor on state container"
az role assignment create `
    --role "Storage Blob Data Contributor" `
    --assignee-object-id $applySpId `
    --assignee-principal-type ServicePrincipal `
    --scope $stateContainerScope `
    --only-show-errors 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Warning "Role assignment failed - check that storage account '$StateAccount' and container '$StateContainer' exist." }

# ── 5. Summary ────────────────────────────────────────────────────────────────
$tenantId = az account show --query tenantId -o tsv

Write-Host ""
Write-Host "======================================================================"
Write-Host "  Setup complete!"
Write-Host ""
Write-Host "  Add these secrets to the '$Env' GitHub Environment:"
Write-Host ""
Write-Host "    AZURE_CLIENT_ID_PLAN   = $planAppId"
Write-Host "    AZURE_CLIENT_ID_APPLY  = $applyAppId"
Write-Host "    AZURE_TENANT_ID        = $tenantId"
Write-Host "    AZURE_SUBSCRIPTION_ID  = $Subscription"
Write-Host ""
Write-Host "  Role Assignments:"
Write-Host "    Plan  (read-only):  Reader + Storage Blob Data Reader"
Write-Host "    Apply (write):      Contributor (RG-scoped) + Storage Blob Data Contributor"
Write-Host "======================================================================"
