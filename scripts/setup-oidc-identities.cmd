@echo off
setlocal

:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
:: setup-oidc-identities.cmd
::
:: Creates SEPARATE Azure AD App Registrations for Plan (read-only) and
:: Apply (scoped-write) per environment, following least-privilege principles.
::
:: Identity Model:
::
::   Plan Identity (read-only)
::   * Reader on target subscription/RG
::   * Storage Blob Data Reader on state container
::   * CANNOT create, modify, or delete any Azure resources
::
::   Used by: Plan job (lint, validate, plan, Checkov, Infracost)
::
::   Apply Identity (scoped-write)
::   * Contributor scoped to TARGET resource group only (not sub-wide)
::   * Storage Blob Data Contributor on state container
::   * CANNOT access other teams' resource groups or state
::
::   Used by: Apply job (terraform apply / destroy)
::
:: Usage:
::   setup-oidc-identities.cmd ^
::     --org myorg ^
::     --repo app-team-repo ^
::     --env Production ^
::     --subscription <SUB_ID> ^
::     --target-rg rg-myapp-prod ^
::     --state-rg rg-terraform-state ^
::     --state-account stterraformstateorg ^
::     --state-container my-team
:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

:: ── Parse arguments ──────────────────────────────────────────────────────────
:parse_args
if "%~1"=="" goto validate_args
if /i "%~1"=="--org"             ( set "ORG=%~2"             & shift & shift & goto parse_args )
if /i "%~1"=="--repo"            ( set "REPO=%~2"            & shift & shift & goto parse_args )
if /i "%~1"=="--env"             ( set "ENV_NAME=%~2"        & shift & shift & goto parse_args )
if /i "%~1"=="--subscription"    ( set "SUB_ID=%~2"          & shift & shift & goto parse_args )
if /i "%~1"=="--target-rg"       ( set "TARGET_RG=%~2"       & shift & shift & goto parse_args )
if /i "%~1"=="--state-rg"        ( set "STATE_RG=%~2"        & shift & shift & goto parse_args )
if /i "%~1"=="--state-account"   ( set "STATE_ACCOUNT=%~2"   & shift & shift & goto parse_args )
if /i "%~1"=="--state-container" ( set "STATE_CONTAINER=%~2" & shift & shift & goto parse_args )
echo Unknown argument: %~1
exit /b 1

:validate_args
if not defined ORG            ( echo ERROR: --org is required            & exit /b 1 )
if not defined REPO           ( echo ERROR: --repo is required           & exit /b 1 )
if not defined ENV_NAME       ( echo ERROR: --env is required            & exit /b 1 )
if not defined SUB_ID         ( echo ERROR: --subscription is required   & exit /b 1 )
if not defined TARGET_RG      ( echo ERROR: --target-rg is required      & exit /b 1 )
if not defined STATE_RG       ( echo ERROR: --state-rg is required       & exit /b 1 )
if not defined STATE_ACCOUNT  ( echo ERROR: --state-account is required  & exit /b 1 )
if not defined STATE_CONTAINER ( echo ERROR: --state-container is required & exit /b 1 )

echo ======================================================================
echo   Setting up OIDC identities for: %ORG%/%REPO% -- %ENV_NAME%
echo ======================================================================

:: ── 1. Create Plan Identity (read-only) ──────────────────────────────────────
set "PLAN_APP_NAME=oidc-%REPO%-%ENV_NAME%-plan"
echo.
echo ^> Creating Plan identity: %PLAN_APP_NAME%

set "PLAN_APP_ID="
for /f "tokens=*" %%i in ('az ad app create --display-name "%PLAN_APP_NAME%" --query appId -o tsv') do set "PLAN_APP_ID=%%i"
if not defined PLAN_APP_ID ( echo ERROR: Failed to create Plan app registration. See az error above. & exit /b 1 )

set "PLAN_OBJ_ID="
for /f "tokens=*" %%i in ('az ad app show --id "%PLAN_APP_ID%" --query id -o tsv') do set "PLAN_OBJ_ID=%%i"
if not defined PLAN_OBJ_ID ( echo ERROR: Failed to retrieve Plan app object ID. & exit /b 1 )

az ad sp create --id "%PLAN_APP_ID%" --only-show-errors
set "PLAN_SP_ID="
for /f "tokens=*" %%i in ('az ad sp show --id "%PLAN_APP_ID%" --query id -o tsv') do set "PLAN_SP_ID=%%i"
if not defined PLAN_SP_ID ( echo ERROR: Failed to retrieve Plan service principal ID. & exit /b 1 )

echo   App ID:  %PLAN_APP_ID%
echo   SP ID:   %PLAN_SP_ID%

:: ── 2. Create Apply Identity (scoped-write) ───────────────────────────────────
set "APPLY_APP_NAME=oidc-%REPO%-%ENV_NAME%-apply"
echo.
echo ^> Creating Apply identity: %APPLY_APP_NAME%

set "APPLY_APP_ID="
for /f "tokens=*" %%i in ('az ad app create --display-name "%APPLY_APP_NAME%" --query appId -o tsv') do set "APPLY_APP_ID=%%i"
if not defined APPLY_APP_ID ( echo ERROR: Failed to create Apply app registration. See az error above. & exit /b 1 )

set "APPLY_OBJ_ID="
for /f "tokens=*" %%i in ('az ad app show --id "%APPLY_APP_ID%" --query id -o tsv') do set "APPLY_OBJ_ID=%%i"
if not defined APPLY_OBJ_ID ( echo ERROR: Failed to retrieve Apply app object ID. & exit /b 1 )

az ad sp create --id "%APPLY_APP_ID%" --only-show-errors
set "APPLY_SP_ID="
for /f "tokens=*" %%i in ('az ad sp show --id "%APPLY_APP_ID%" --query id -o tsv') do set "APPLY_SP_ID=%%i"
if not defined APPLY_SP_ID ( echo ERROR: Failed to retrieve Apply service principal ID. & exit /b 1 )

echo   App ID:  %APPLY_APP_ID%
echo   SP ID:   %APPLY_SP_ID%

:: ── 3. Add OIDC Federated Credentials ────────────────────────────────────────
set "ISSUER=https://token.actions.githubusercontent.com"
set "AUDIENCE=api://AzureADTokenExchange"
set "SUBJECT=repo:%ORG%/%REPO%:environment:%ENV_NAME%"

echo.
echo ^> Adding federated credentials (subject: %SUBJECT%)

:: Write JSON to temp files to avoid quoting issues on the command line
(
  echo {
  echo   "name": "github-%ENV_NAME%-plan",
  echo   "issuer": "%ISSUER%",
  echo   "subject": "%SUBJECT%",
  echo   "audiences": ["%AUDIENCE%"],
  echo   "description": "Read-only Plan identity for %REPO% %ENV_NAME%"
  echo }
) > "%TEMP%\plan_fed_cred.json"

(
  echo {
  echo   "name": "github-%ENV_NAME%-apply",
  echo   "issuer": "%ISSUER%",
  echo   "subject": "%SUBJECT%",
  echo   "audiences": ["%AUDIENCE%"],
  echo   "description": "Scoped-write Apply identity for %REPO% %ENV_NAME%"
  echo }
) > "%TEMP%\apply_fed_cred.json"

az ad app federated-credential create --id "%PLAN_OBJ_ID%"  --parameters "@%TEMP%\plan_fed_cred.json"  --only-show-errors >nul
az ad app federated-credential create --id "%APPLY_OBJ_ID%" --parameters "@%TEMP%\apply_fed_cred.json" --only-show-errors >nul

del "%TEMP%\plan_fed_cred.json"  >nul 2>&1
del "%TEMP%\apply_fed_cred.json" >nul 2>&1

echo   Federated credentials created

:: ── 4. Assign RBAC Roles ──────────────────────────────────────────────────────
echo.
echo ^> Assigning RBAC roles...

set "TARGET_RG_SCOPE=/subscriptions/%SUB_ID%/resourceGroups/%TARGET_RG%"
set "STATE_ACCOUNT_SCOPE=/subscriptions/%SUB_ID%/resourceGroups/%STATE_RG%/providers/Microsoft.Storage/storageAccounts/%STATE_ACCOUNT%"
set "STATE_CONTAINER_SCOPE=%STATE_ACCOUNT_SCOPE%/blobServices/default/containers/%STATE_CONTAINER%"

:: Plan Identity Roles (READ-ONLY)
echo   Plan identity -^> Reader on target RG
az role assignment create ^
  --role "Reader" ^
  --assignee-object-id "%PLAN_SP_ID%" ^
  --assignee-principal-type ServicePrincipal ^
  --scope "%TARGET_RG_SCOPE%" ^
  --only-show-errors >nul

echo   Plan identity -^> Storage Blob Data Reader on state container
az role assignment create ^
  --role "Storage Blob Data Reader" ^
  --assignee-object-id "%PLAN_SP_ID%" ^
  --assignee-principal-type ServicePrincipal ^
  --scope "%STATE_CONTAINER_SCOPE%" ^
  --only-show-errors >nul

:: Apply Identity Roles (SCOPED WRITE)
echo   Apply identity -^> Contributor on target RG (scoped)
az role assignment create ^
  --role "Contributor" ^
  --assignee-object-id "%APPLY_SP_ID%" ^
  --assignee-principal-type ServicePrincipal ^
  --scope "%TARGET_RG_SCOPE%" ^
  --only-show-errors >nul

echo   Apply identity -^> Storage Blob Data Contributor on state container
az role assignment create ^
  --role "Storage Blob Data Contributor" ^
  --assignee-object-id "%APPLY_SP_ID%" ^
  --assignee-principal-type ServicePrincipal ^
  --scope "%STATE_CONTAINER_SCOPE%" ^
  --only-show-errors >nul

:: ── 5. Summary ────────────────────────────────────────────────────────────────
set "TENANT_ID="
for /f "tokens=*" %%i in ('az account show --query tenantId -o tsv') do set "TENANT_ID=%%i"
if not defined TENANT_ID ( echo ERROR: Failed to retrieve tenant ID. & exit /b 1 )

echo.
echo ======================================================================
echo   Setup complete!
echo.
echo   Add these secrets to the '%ENV_NAME%' GitHub Environment:
echo.
echo     AZURE_CLIENT_ID_PLAN   = %PLAN_APP_ID%
echo     AZURE_CLIENT_ID_APPLY  = %APPLY_APP_ID%
echo     AZURE_TENANT_ID        = %TENANT_ID%
echo     AZURE_SUBSCRIPTION_ID  = %SUB_ID%
echo.
echo   Role Assignments:
echo     Plan  (read-only):  Reader + Storage Blob Data Reader
echo     Apply (write):      Contributor (RG-scoped) + Storage Blob Data Contributor
echo ======================================================================

endlocal
exit /b 0
