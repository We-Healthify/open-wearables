<#
.SYNOPSIS
Optionally verifies local API access and dispatches synthetic sample generation.

.DESCRIPTION
Run after setup.ps1 and after the Docker API has finished starting on port 8100.
Uses the developer credentials from .local/open-wearables/backend.env to check
OpenAPI access and login. Creates a temporary API key, retrieves users and, when
a synthetic user appears on the first results page, its workouts and sleep.
The temporary key is revoked in finally, including when retrieval fails.

Responses overwrite users.json, workouts.json and sleep.json in the ignored
.local/open-wearables/ directory when their corresponding requests succeed.
The script does not start services and is not required for daily startup.
It checks API access; portal sign-in and visual inspection are separate checks.

.PARAMETER Seed
Dispatches one Minimal (Quick) synthetic user through Celery with seed 20261125.
Every invocation adds a user; it does not reset or deduplicate existing data.
Generation is asynchronous. Wait for the worker and rerun without -Seed if the
new user's records are not yet available. No real patient data is imported.

.EXAMPLE
./local-dev/verify.ps1
Checks the running local API without generating another synthetic user.

.EXAMPLE
./local-dev/verify.ps1 -Seed
Checks API access and dispatches generation of one additional synthetic user.
#>
param([switch]$Seed)
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$configuration = @{}
Get-Content (Join-Path $repoRoot '.local/open-wearables/backend.env') | ForEach-Object {
    if ($_ -match '^([^#=]+)=(.*)$') { $configuration[$matches[1]] = $matches[2] }
}
$baseUrl = 'http://localhost:8100'
$schema = Invoke-RestMethod "$baseUrl/openapi.json"
Write-Host "OpenAPI available: $($schema.info.title)"
$login = Invoke-RestMethod "$baseUrl/api/v1/auth/login" -Method Post -Body @{
    username = $configuration.ADMIN_EMAIL
    password = $configuration.ADMIN_PASSWORD
}
$developerHeaders = @{ Authorization = "Bearer $($login.access_token)" }
Write-Host 'Developer login succeeded.'
if ($Seed) {
    # Reuse the API's preset configuration rather than maintaining a duplicate.
    $presets = Invoke-RestMethod "$baseUrl/api/v1/settings/seed/presets" -Headers $developerHeaders
    $preset = $presets | Where-Object { $_.label -eq 'Minimal (Quick)' }
    if (!$preset) { throw 'Expected Minimal (Quick) seed preset is missing.' }
    $seedRequest = @{ num_users = 1; random_seed = 20261125; profile = $preset.profile } | ConvertTo-Json -Depth 20
    $dispatch = Invoke-RestMethod "$baseUrl/api/v1/settings/seed" -Method Post -Headers $developerHeaders -ContentType 'application/json' -Body $seedRequest
    Write-Host "Synthetic generation dispatched: $($dispatch.task_id). Wait for the worker, then rerun without -Seed."
}
$key = Invoke-RestMethod "$baseUrl/api/v1/developer/api-keys" -Method Post -Headers $developerHeaders -ContentType 'application/json' -Body '{"name":"Local verification (temporary)"}'
# Exercise API-key authentication separately from the developer JWT login.
try {
    $apiHeaders = @{ 'X-Open-Wearables-API-Key' = $key.key }
    $users = Invoke-RestMethod "$baseUrl/api/v1/users" -Headers $apiHeaders
    Write-Host 'Authenticated API-key users request succeeded.'
    $users | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $repoRoot '.local/open-wearables/users.json')
    Write-Host 'User response saved locally to .local/open-wearables/users.json.'
    $syntheticUser = $users.items | Where-Object { $_.first_name -like '[[]SEED:*' } | Select-Object -First 1
    if ($syntheticUser) {
        $startDate = [DateTime]::UtcNow.AddMonths(-7).ToString('yyyy-MM-dd')
        $endDate = [DateTime]::UtcNow.AddDays(1).ToString('yyyy-MM-dd')
        foreach ($category in @('workouts', 'sleep')) {
            $records = Invoke-RestMethod "$baseUrl/api/v1/users/$($syntheticUser.id)/events/${category}?start_date=$startDate&end_date=$endDate" -Headers $apiHeaders
            $records | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $repoRoot ".local/open-wearables/$category.json")
            Write-Host "Synthetic $category retrieved; response saved locally."
        }
    }
} finally {
    # Avoid leaving a reusable verification credential in the local database.
    Invoke-RestMethod "$baseUrl/api/v1/developer/api-keys/$($key.id)" -Method Delete -Headers $developerHeaders | Out-Null
}
