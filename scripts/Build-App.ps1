param(
    [string]$FlutterHome = '',
    [string]$ApiUrl = '',
    [string]$DemoEmail = '',
    [string]$DemoPassword = ''
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$configFile = Join-Path $projectRoot 'config/local.json'
if (-not (Test-Path -LiteralPath $configFile)) {
    throw 'Copy config/local.example.json to config/local.json and fill the Supabase project URL and publishable key.'
}
$clientConfig = Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json
foreach ($key in @('SUPABASE_URL', 'SUPABASE_PUBLISHABLE_KEY')) {
    if (-not $clientConfig.$key) { throw "config/local.json is missing $key." }
}
$buildArguments = @('build', 'apk', '--debug', '--target-platform', 'android-arm64', '--split-per-abi', '--dart-define-from-file=../config/local.json')
if ($ApiUrl) {
    $apiOrigin = $null
    if (-not [Uri]::TryCreate($ApiUrl, [UriKind]::Absolute, [ref]$apiOrigin) -or
        $apiOrigin.Scheme -ne 'https' -or $apiOrigin.UserInfo -or $apiOrigin.Query -or
        $apiOrigin.Fragment -or $apiOrigin.AbsolutePath -ne '/') {
        throw 'ApiUrl must be an HTTPS origin without a path, credentials, query or fragment.'
    }
    $buildArguments += "--dart-define=SHELFSIGHT_API_URL=$($ApiUrl.TrimEnd('/'))"
}
if (($DemoEmail -and -not $DemoPassword) -or ($DemoPassword -and -not $DemoEmail)) {
    throw 'DemoEmail and DemoPassword must be supplied together.'
}
if ($DemoEmail) {
    if ($DemoEmail -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$') {
        throw 'DemoEmail must be a valid email address.'
    }
    if ($DemoPassword.Length -lt 6) {
        throw 'DemoPassword must contain at least 6 characters.'
    }
    $buildArguments += '--dart-define=SHELFSIGHT_ENABLE_DEMO_ACCOUNT=true'
    $buildArguments += "--dart-define=SHELFSIGHT_DEMO_EMAIL=$DemoEmail"
    $buildArguments += "--dart-define=SHELFSIGHT_DEMO_PASSWORD=$DemoPassword"
}
$flutterCommand = 'flutter'
if ($FlutterHome) { $flutterCommand = Join-Path $FlutterHome 'bin/flutter.bat' }
elseif (Test-Path (Join-Path $env:USERPROFILE 'tools/flutter_shelfsight/bin/flutter.bat')) {
    $flutterCommand = Join-Path $env:USERPROFILE 'tools/flutter_shelfsight/bin/flutter.bat'
}
Push-Location (Join-Path $projectRoot 'app')
try {
    & $flutterCommand pub get
    if ($LASTEXITCODE -ne 0) { throw 'Flutter package restore failed.' }
    & $flutterCommand @buildArguments
    if ($LASTEXITCODE -ne 0) { throw 'APK build failed.' }
} finally { Pop-Location }
Write-Host "Android APK: $(Join-Path $projectRoot 'app/build/app/outputs/flutter-apk/app-arm64-v8a-debug.apk')"
