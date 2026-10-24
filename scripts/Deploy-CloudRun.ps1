[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z][a-z0-9-]{4,28}[a-z0-9]$')]
    [string]$ProjectId,
    [ValidatePattern('^[a-z]+-[a-z]+[0-9]$')]
    [string]$Region = 'asia-south1',
    [ValidatePattern('^[a-z][a-z0-9-]{0,48}[a-z0-9]$')]
    [string]$ServiceName = 'shelfsight-api',
    [string]$SupabaseUrl = '',
    [string]$SupabasePublishableKey = '',
    [ValidatePattern('^$|^[A-Za-z0-9_-]+$')]
    [string]$GeminiSecret = '',
    [ValidatePattern('^$|^[A-Za-z0-9._/-]+$')]
    [string]$GeminiModel = ''
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$localConfigPath = Join-Path $projectRoot 'config/local.json'
if ((-not $SupabaseUrl -or -not $SupabasePublishableKey) -and (Test-Path -LiteralPath $localConfigPath)) {
    $localConfig = Get-Content -LiteralPath $localConfigPath -Raw | ConvertFrom-Json
    if (-not $SupabaseUrl) { $SupabaseUrl = $localConfig.SUPABASE_URL }
    if (-not $SupabasePublishableKey) { $SupabasePublishableKey = $localConfig.SUPABASE_PUBLISHABLE_KEY }
}
if ($SupabaseUrl -notmatch '^https://[a-z0-9-]+\.supabase\.co$' -or -not $SupabasePublishableKey) {
    throw 'Configure SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY in config/local.json or pass both values.'
}
if ([bool]$GeminiSecret -ne [bool]$GeminiModel) {
    throw 'Supply GeminiSecret and GeminiModel together, or omit both to leave shelf vision unavailable.'
}
if (-not (Get-Command gcloud -ErrorAction SilentlyContinue)) {
    throw 'Install the Google Cloud CLI and run gcloud auth login first.'
}

function Invoke-Gcloud {
    param([string[]]$Arguments)
    $result = & gcloud @Arguments
    if ($LASTEXITCODE -ne 0) { throw "gcloud failed: $($Arguments[0..1] -join ' ')" }
    return $result
}

# Do not start a build or enable services until billing is confirmed.
$billing = Invoke-Gcloud -Arguments @(
    'billing', 'projects', 'describe', $ProjectId, '--format=value(billingEnabled)'
)
if (($billing | Out-String).Trim() -ne 'True') {
    throw "Billing is disabled for $ProjectId. Enable it at https://console.cloud.google.com/billing/linkedaccount?project=$ProjectId and rerun."
}

$modelPath = Join-Path $projectRoot 'runtime/models/detector.tflite'
if (-not (Test-Path -LiteralPath $modelPath -PathType Leaf)) {
    throw 'Provide a verified person detector at runtime/models/detector.tflite before deploying.'
}

Invoke-Gcloud -Arguments @(
    'services', 'enable', 'run.googleapis.com', 'cloudbuild.googleapis.com',
    'artifactregistry.googleapis.com', "--project=$ProjectId", '--quiet'
) | Out-Host

$environment = "SHELFSIGHT_SUPABASE_URL=$SupabaseUrl,SHELFSIGHT_SUPABASE_PUBLISHABLE_KEY=$SupabasePublishableKey,SHELFSIGHT_CLOUD_MODE=true"
if ($GeminiModel) { $environment += ",SHELFSIGHT_GEMINI_MODEL=$GeminiModel" }
$deployArguments = @(
    'run', 'deploy', $ServiceName, "--project=$ProjectId", "--region=$Region",
    "--source=$projectRoot", '--allow-unauthenticated', '--port=8080',
    '--cpu=2', '--memory=1Gi', '--max-instances=1', '--min-instances=0',
    '--concurrency=20', '--timeout=3600', "--set-env-vars=$environment", '--quiet'
)
if ($GeminiSecret) {
    $deployArguments += "--set-secrets=SHELFSIGHT_GEMINI_API_KEY=${GeminiSecret}:latest"
}
Invoke-Gcloud -Arguments $deployArguments | Out-Host

$serviceUrl = ((Invoke-Gcloud -Arguments @(
    'run', 'services', 'describe', $ServiceName, "--project=$ProjectId",
    "--region=$Region", '--format=value(status.url)'
)) | Out-String).Trim()
if ($serviceUrl -notmatch '^https://[^/]+\.run\.app$') {
    throw 'Deployment returned no valid Cloud Run service URL.'
}
$health = Invoke-RestMethod -Uri "$serviceUrl/health" -TimeoutSec 60
if ($health.status -ne 'ok') { throw 'Cloud Run health verification failed.' }
$guard = Invoke-WebRequest -Uri "$serviceUrl/v1/stores" -TimeoutSec 60 -SkipHttpErrorCheck
if ($guard.StatusCode -ne 401) {
    throw 'The deployed API did not enforce authentication on store data.'
}
Write-Host "Verified API address (enter this in the Android app): $serviceUrl"
$serviceUrl
