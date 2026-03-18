#!/usr/bin/env bash
###############################################################################
# setup-oidc-identities.sh
#
# Creates SEPARATE Azure AD App Registrations for Plan (read-only) and
# Apply (scoped-write) per environment, following least-privilege principles.
#
# Identity Model:
#
#   ┌─────────────────────────────────────────────────────────────────────┐
#   │  Plan Identity (read-only)                                          │
#   │  • Reader on target subscription/RG                                │
#   │  • Storage Blob Data Reader on state container                     │
#   │  • CANNOT create, modify, or delete any Azure resources            │
#   │                                                                     │
#   │  Used by: Plan job (lint, validate, plan, Checkov, Infracost)      │
#   └─────────────────────────────────────────────────────────────────────┘
#
#   ┌─────────────────────────────────────────────────────────────────────┐
#   │  Apply Identity (scoped-write)                                      │
#   │  • Contributor scoped to TARGET resource group only (not sub-wide) │
#   │  • Storage Blob Data Contributor on state container                │
#   │  • CANNOT access other teams' resource groups or state             │
#   │                                                                     │
#   │  Used by: Apply job (terraform apply / destroy)                    │
#   └─────────────────────────────────────────────────────────────────────┘
#
# Usage:
#   chmod +x setup-oidc-identities.sh
#   ./setup-oidc-identities.sh \
#     --org myorg \
#     --repo app-team-repo \
#     --env Production \
#     --subscription <SUB_ID> \
#     --target-rg rg-myapp-prod \
#     --state-rg rg-terraform-state \
#     --state-account stterraformstateorg \
#     --state-container my-team
#
###############################################################################

set -euo pipefail

# ── Parse arguments ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --org)           ORG="$2"; shift 2;;
    --repo)          REPO="$2"; shift 2;;
    --env)           ENV_NAME="$2"; shift 2;;
    --subscription)  SUB_ID="$2"; shift 2;;
    --target-rg)     TARGET_RG="$2"; shift 2;;
    --state-rg)      STATE_RG="$2"; shift 2;;
    --state-account) STATE_ACCOUNT="$2"; shift 2;;
    --state-container) STATE_CONTAINER="$2"; shift 2;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

echo "══════════════════════════════════════════════════════════════════════"
echo "  Setting up OIDC identities for: ${ORG}/${REPO} — ${ENV_NAME}"
echo "══════════════════════════════════════════════════════════════════════"

# ── 1. Create Plan Identity (read-only) ─────────────────────────────────────
PLAN_APP_NAME="oidc-${REPO}-${ENV_NAME}-plan"
echo ""
echo "▸ Creating Plan identity: ${PLAN_APP_NAME}"

PLAN_APP_ID=$(az ad app create \
  --display-name "${PLAN_APP_NAME}" \
  --query appId -o tsv)

PLAN_OBJ_ID=$(az ad app show --id "${PLAN_APP_ID}" --query id -o tsv)

# Create service principal
az ad sp create --id "${PLAN_APP_ID}" --only-show-errors > /dev/null 2>&1 || true
PLAN_SP_ID=$(az ad sp show --id "${PLAN_APP_ID}" --query id -o tsv)

echo "  App ID:  ${PLAN_APP_ID}"
echo "  SP ID:   ${PLAN_SP_ID}"

# ── 2. Create Apply Identity (scoped-write) ─────────────────────────────────
APPLY_APP_NAME="oidc-${REPO}-${ENV_NAME}-apply"
echo ""
echo "▸ Creating Apply identity: ${APPLY_APP_NAME}"

APPLY_APP_ID=$(az ad app create \
  --display-name "${APPLY_APP_NAME}" \
  --query appId -o tsv)

APPLY_OBJ_ID=$(az ad app show --id "${APPLY_APP_ID}" --query id -o tsv)

# Create service principal
az ad sp create --id "${APPLY_APP_ID}" --only-show-errors > /dev/null 2>&1 || true
APPLY_SP_ID=$(az ad sp show --id "${APPLY_APP_ID}" --query id -o tsv)

echo "  App ID:  ${APPLY_APP_ID}"
echo "  SP ID:   ${APPLY_SP_ID}"

# ── 3. Add OIDC Federated Credentials ───────────────────────────────────────
ISSUER="https://token.actions.githubusercontent.com"
AUDIENCE="api://AzureADTokenExchange"
SUBJECT="repo:${ORG}/${REPO}:environment:${ENV_NAME}"

echo ""
echo "▸ Adding federated credentials (subject: ${SUBJECT})"

# Plan identity federated credential
az ad app federated-credential create \
  --id "${PLAN_OBJ_ID}" \
  --parameters "{
    \"name\": \"github-${ENV_NAME}-plan\",
    \"issuer\": \"${ISSUER}\",
    \"subject\": \"${SUBJECT}\",
    \"audiences\": [\"${AUDIENCE}\"],
    \"description\": \"Read-only Plan identity for ${REPO} ${ENV_NAME}\"
  }" --only-show-errors > /dev/null

# Apply identity federated credential
az ad app federated-credential create \
  --id "${APPLY_OBJ_ID}" \
  --parameters "{
    \"name\": \"github-${ENV_NAME}-apply\",
    \"issuer\": \"${ISSUER}\",
    \"subject\": \"${SUBJECT}\",
    \"audiences\": [\"${AUDIENCE}\"],
    \"description\": \"Scoped-write Apply identity for ${REPO} ${ENV_NAME}\"
  }" --only-show-errors > /dev/null

echo "  ✅ Federated credentials created"

# ── 4. Assign RBAC Roles ────────────────────────────────────────────────────
echo ""
echo "▸ Assigning RBAC roles..."

TARGET_RG_SCOPE="/subscriptions/${SUB_ID}/resourceGroups/${TARGET_RG}"
STATE_ACCOUNT_SCOPE="/subscriptions/${SUB_ID}/resourceGroups/${STATE_RG}/providers/Microsoft.Storage/storageAccounts/${STATE_ACCOUNT}"
STATE_CONTAINER_SCOPE="${STATE_ACCOUNT_SCOPE}/blobServices/default/containers/${STATE_CONTAINER}"

# ─── Plan Identity Roles (READ-ONLY) ───
echo "  Plan identity → Reader on target RG"
az role assignment create \
  --role "Reader" \
  --assignee-object-id "${PLAN_SP_ID}" \
  --assignee-principal-type ServicePrincipal \
  --scope "${TARGET_RG_SCOPE}" \
  --only-show-errors > /dev/null

echo "  Plan identity → Storage Blob Data Reader on state container"
az role assignment create \
  --role "Storage Blob Data Reader" \
  --assignee-object-id "${PLAN_SP_ID}" \
  --assignee-principal-type ServicePrincipal \
  --scope "${STATE_CONTAINER_SCOPE}" \
  --only-show-errors > /dev/null

# ─── Apply Identity Roles (SCOPED WRITE) ───
echo "  Apply identity → Contributor on target RG (scoped)"
az role assignment create \
  --role "Contributor" \
  --assignee-object-id "${APPLY_SP_ID}" \
  --assignee-principal-type ServicePrincipal \
  --scope "${TARGET_RG_SCOPE}" \
  --only-show-errors > /dev/null

echo "  Apply identity → Storage Blob Data Contributor on state container"
az role assignment create \
  --role "Storage Blob Data Contributor" \
  --assignee-object-id "${APPLY_SP_ID}" \
  --assignee-principal-type ServicePrincipal \
  --scope "${STATE_CONTAINER_SCOPE}" \
  --only-show-errors > /dev/null

# ── 5. Summary ───────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════════════════════"
echo "  ✅ Setup complete!"
echo ""
echo "  Add these secrets to the '${ENV_NAME}' GitHub Environment:"
echo ""
echo "    AZURE_CLIENT_ID_PLAN   = ${PLAN_APP_ID}"
echo "    AZURE_CLIENT_ID_APPLY  = ${APPLY_APP_ID}"
echo "    AZURE_TENANT_ID        = $(az account show --query tenantId -o tsv)"
echo "    AZURE_SUBSCRIPTION_ID  = ${SUB_ID}"
echo ""
echo "  Role Assignments:"
echo "    Plan  (read-only):  Reader + Storage Blob Data Reader"
echo "    Apply (write):      Contributor (RG-scoped) + Storage Blob Data Contributor"
echo "══════════════════════════════════════════════════════════════════════"
