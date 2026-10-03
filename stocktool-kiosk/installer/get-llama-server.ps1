<#
.SYNOPSIS
    Downloads the prebuilt, CPU-only llama-server.exe from llama.cpp's
    own GitHub releases into vendor\llama, so build.ps1/build.spec can
    bundle it into StockToolKiosk.exe -- no compiler, no CMake, no
    llama-cpp-python. Run this once (and again whenever you want to
    pick up a newer llama.cpp release); the build itself doesn't need
    network access if vendor\llama\llama-server.exe already exists.

.PARAMETER Tag
    A specific llama.cpp release tag (e.g. "b10423"). Defaults to
    "latest", which does NOT mean GitHub's "Latest release" -- llama.cpp
    tags stable source-only releases as vX.Y.Z (see BUILD.md note below)
    and those get marked "Latest" on GitHub despite shipping no binary
    assets at all. "latest" here instead means: search recent releases
    for the newest one that actually has a Windows CPU zip attached,
    which in practice is always one of the frequent b[NUM] tags.

.EXAMPLE
    .\installer\get-llama-server.ps1
.EXAMPLE
    .\installer\get-llama-server.ps1 -Tag b10423
#>
param(
    [string]$Tag = "latest"
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$VendorDir = Join-Path $Root "vendor\llama"
$Headers = @{ "User-Agent" = "StockToolKiosk-build" }

function Write-Step($msg) { Write-Host ""; Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "  OK: $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "  WARNING: $msg" -ForegroundColor Yellow }

# Naming has varied across llama.cpp releases (win-cpu-x64 vs
# win-avx2-x64) -- match anything Windows + CPU-flavoured, and
# explicitly exclude CUDA/Vulkan/SYCL/HIP/ROCm variants, which need GPU
# drivers this kiosk can't assume are present (spec: "run within the
# current spec", i.e. no new hardware requirement).
function Find-CpuAsset($release) {
    return $release.assets | Where-Object {
        $_.name -match "(?i)win.*(cpu|avx2).*x64\.zip$" -and
        $_.name -notmatch "(?i)cuda|vulkan|sycl|hip|rocm"
    } | Select-Object -First 1
}

Write-Step "Resolving llama.cpp release ($Tag)"

if ($Tag -ne "latest") {
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/ggml-org/llama.cpp/releases/tags/$Tag" -Headers $Headers
    $asset = Find-CpuAsset $release
    if (-not $asset) {
        throw "Release $Tag has no matching Windows CPU asset -- check " +
              "https://github.com/ggml-org/llama.cpp/releases/tag/$Tag directly."
    }
} else {
    # IMPORTANT: NOT /releases/latest -- llama.cpp's "Latest" release on
    # GitHub is often a source-only vX.Y.Z semantic-versioned tag with
    # zero binary assets (see the docstring above). Binaries attach to
    # the much more frequent b[NUM] "nightly" tags instead, so this
    # walks the recent-releases list (newest first) and takes the first
    # one that actually has a Windows CPU zip attached.
    $release = $null
    $asset = $null
    $page = 1
    while (-not $asset -and $page -le 3) {
        $batch = Invoke-RestMethod -Uri "https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=30&page=$page" -Headers $Headers
        if (-not $batch -or $batch.Count -eq 0) { break }
        foreach ($candidate in $batch) {
            $found = Find-CpuAsset $candidate
            if ($found) { $release = $candidate; $asset = $found; break }
        }
        $page++
    }
    if (-not $asset) {
        throw "Could not find any recent llama.cpp release with a Windows CPU asset across " +
              "$($page - 1) page(s) of releases. Browse " +
              "https://github.com/ggml-org/llama.cpp/releases yourself, pick a b[NUM] tag that " +
              "has one, and re-run with -Tag <that tag>."
    }
}

Write-Ok "Using release $($release.tag_name)"
Write-Ok "Asset: $($asset.name) ($([math]::Round($asset.size / 1MB, 1)) MB)"

if (Test-Path $VendorDir) { Remove-Item $VendorDir -Recurse -Force }
New-Item -ItemType Directory -Path $VendorDir -Force | Out-Null

$zipPath = Join-Path $env:TEMP $asset.name
Write-Step "Downloading $($asset.name)"
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -UserAgent "StockToolKiosk-build"
Write-Ok "Downloaded to $zipPath"

Write-Step "Extracting"
$extractDir = Join-Path $env:TEMP "llama-extract-$($release.tag_name)"
if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force

# The zip may nest everything under a subfolder (e.g. "build\bin\") --
# find llama-server.exe wherever it landed and copy the whole folder
# it's in (DLLs it needs sit next to it), not just the one exe.
$serverExe = Get-ChildItem -Path $extractDir -Filter "llama-server.exe" -Recurse | Select-Object -First 1
if (-not $serverExe) {
    throw "llama-server.exe not found inside $($asset.name) -- the release layout may have changed."
}
Copy-Item -Path (Join-Path $serverExe.Directory.FullName "*") -Destination $VendorDir -Recurse -Force
Write-Ok "Installed to $VendorDir"

Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue

"$($release.tag_name)" | Set-Content (Join-Path $VendorDir "VERSION.txt")

Write-Host ""
Write-Host "Done. vendor\llama\llama-server.exe is ready for build.ps1 / build.spec to bundle." -ForegroundColor Green
Write-Host "An admin still needs to place a .gguf model file and set its path on the AI Settings page -- this script only installs the engine, not a model." -ForegroundColor Yellow
