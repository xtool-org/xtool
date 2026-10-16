# Repair a broken winget Swift.Toolchain install on Windows.
# The winget package installs the compiler but misses the stdlib junctions
# and the SDKROOT env var, so any `import Foundation` compile fails with
# "missing required modules: '_complex', 'ucrt'".
#
# Run in PowerShell (no admin needed; junctions work without elevation).

$ErrorActionPreference = 'Stop'

$swiftRoot = "$env:LOCALAPPDATA\Programs\Swift"
$tc = Get-ChildItem "$swiftRoot\Toolchains" -Directory | Select-Object -First 1
if (-not $tc) { throw "Swift toolchain not found under $swiftRoot" }
$plat = Get-ChildItem "$swiftRoot\Platforms" -Directory | Select-Object -First 1
if (-not $plat) { throw "Swift platforms not found under $swiftRoot" }

$tcRoot = $tc.FullName
$wsdk = "$($plat.FullName)\Windows.platform\Developer\SDKs\Windows.sdk"

Write-Host "Toolchain: $tcRoot"
Write-Host "Windows SDK: $wsdk"

$tcSwift = "$tcRoot\usr\lib\swift"
$wsdkLib = "$wsdk\usr\lib"

# 1. Junctions for the stdlib pieces the driver resolves relative to the toolchain.
$links = @(
    @{ Name = "windows";      Target = "$wsdkLib\swift\windows" },
    @{ Name = "swift_static"; Target = "$wsdkLib\swift_static" },
    @{ Name = "apinotes";     Target = "$wsdkLib\swift\apinotes" },
    @{ Name = "shims";        Target = "$wsdkLib\swift\shims" }
)
foreach ($l in $links) {
    $dst = Join-Path $tcSwift $l.Name
    if (Test-Path $dst) {
        Write-Host "exists: $dst"
    } else {
        New-Item -ItemType Junction -Path $dst -Target $l.Target | Out-Null
        Write-Host "linked: $dst -> $($l.Target)"
    }
}

# 2. SDKROOT env var (user scope).
[Environment]::SetEnvironmentVariable('SDKROOT', $wsdk, 'User')
Write-Host "SDKROOT (user) = $wsdk"

# 3. Clear stale clang module cache.
Remove-Item "$env:LOCALAPPDATA\clang\ModuleCache" -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "Done. Reopen your shell (or set `$env:SDKROOT in-process) and build from an"
Write-Host "MSVC developer prompt (VsDevCmd) so INCLUDE/LIB are set."
