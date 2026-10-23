param([string]$Address = '')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Push-Location (Join-Path $projectRoot 'server')
try {
    if ($Address) { $env:SHELFSIGHT_PUBLIC_ADDRESS = $Address }
    uv run python -m shelfsight
    if ($LASTEXITCODE -ne 0) { throw 'Server exited with an error.' }
} finally { Pop-Location }
