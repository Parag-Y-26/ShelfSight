param([string]$FlutterHome = '')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$flutterCommand = 'flutter'
if ($FlutterHome) { $flutterCommand = Join-Path $FlutterHome 'bin/flutter.bat' }
elseif (Test-Path (Join-Path $env:USERPROFILE 'tools/flutter_shelfsight/bin/flutter.bat')) {
    $flutterCommand = Join-Path $env:USERPROFILE 'tools/flutter_shelfsight/bin/flutter.bat'
}
Copy-Item -LiteralPath (Join-Path $projectRoot 'config/defaults.json') -Destination (Join-Path $projectRoot 'app/assets/defaults.json')
Push-Location (Join-Path $projectRoot 'app')
try {
    & $flutterCommand pub get
    if ($LASTEXITCODE -ne 0) { throw 'Flutter package restore failed.' }
    & $flutterCommand build apk --debug --dart-define-from-file=../config/local.json
    if ($LASTEXITCODE -ne 0) { throw 'APK build failed.' }
} finally { Pop-Location }
