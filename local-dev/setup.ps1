<#
.SYNOPSIS
Prepares environment files for the isolated local Open Wearables sandbox.

.DESCRIPTION
Run once before the first Docker Compose start. Checks that the tested upstream
commit is an ancestor of HEAD and that application source still matches that
commit. Committed, staged and unstaged setup changes under local-dev/ and to
.gitignore are allowed. Untracked files outside those paths are rejected.

Creates missing backend.env and frontend.env files in .local/open-wearables/,
including a random signing secret and developer password. Existing files are
preserved, so rerunning does not reset credentials or database contents.
These files contain local secrets and must remain ignored by Git.

This script does not build images, start containers, or load sample data.
For daily startup, use Docker Compose directly; no PowerShell script is needed.

.EXAMPLE
./local-dev/setup.ps1
Run from the repository root to prepare a fresh local environment.
Then run: docker compose -f local-dev/compose.yml up -d --build
#>
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$sourcePath = $repoRoot
$pinnedCommit = '6811b286c95389d2be20d293d32f393ae4d8a101'

if (!(Test-Path (Join-Path $sourcePath '.git'))) {
    throw 'Run this script from a Git checkout of Open Wearables.'
}
git -C $sourcePath merge-base --is-ancestor $pinnedCommit HEAD
if ($LASTEXITCODE -eq 1) {
    throw "This checkout must descend from tested upstream commit $pinnedCommit."
}
if ($LASTEXITCODE -ne 0) { throw 'Cannot verify the pinned upstream commit.' }
# Compare actual tracked source against the pin, rather than requiring HEAD to
# equal it: our own setup commits legitimately change HEAD without upgrading OW.
$sourcePaths = @('--', '.', ':!local-dev', ':!.gitignore')
git -C $sourcePath diff --quiet $pinnedCommit @sourcePaths
if ($LASTEXITCODE -eq 1) {
    throw "Application source differs from tested upstream commit $pinnedCommit. Review the changes and update the pin deliberately before setup."
}
if ($LASTEXITCODE -ne 0) { throw 'Cannot compare application source with the pin.' }
$untrackedFiles = git -C $sourcePath ls-files --others --exclude-standard @sourcePaths
if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect untracked source files.' }
if ($untrackedFiles) { throw 'Untracked files exist outside local-dev/. Keep the pinned application source clean before setup.' }

$localPath = Join-Path $repoRoot '.local/open-wearables'
# Keep generated credentials outside tracked source and preserve them on reruns.
New-Item -ItemType Directory -Force $localPath | Out-Null
$backendPath = Join-Path $localPath 'backend.env'
if (!(Test-Path $backendPath)) {
    $randomBytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($randomBytes)
    $secret = -join ($randomBytes | ForEach-Object { $_.ToString('x2') })
    $rng.GetBytes($randomBytes)
    $adminPassword = [Convert]::ToBase64String($randomBytes)
    $rng.Dispose()
    @"
ENVIRONMENT=local
API_PORT=8000
SECRET_KEY=$secret
ADMIN_EMAIL=developer@example.com
ADMIN_PASSWORD=$adminPassword
DB_HOST=db
DB_PORT=5432
DB_NAME=open-wearables
DB_USER=open-wearables
DB_PASSWORD=local-synthetic-only
REDIS_HOST=redis
REDIS_PORT=6379
CORS_ORIGINS=["http://localhost:3100"]
FRONTEND_URL=http://localhost:3100
API_BASE_URL=http://localhost:8100
TELEMETRY_ENABLED=false
SENTRY_ENABLED=false
OUTGOING_WEBHOOKS_ENABLED=false
OW_SCORES_ENABLED=false
"@ | Set-Content -Encoding ascii $backendPath
}
$frontendPath = Join-Path $localPath 'frontend.env'
if (!(Test-Path $frontendPath)) {
    "VITE_API_URL=http://localhost:8100`nAPI_URL=http://app:8000" | Set-Content -Encoding ascii $frontendPath
}
Write-Host "Environment ready. Local credentials: $backendPath"
Write-Host 'From the open-wearables root: docker compose -f local-dev/compose.yml up -d --build'
