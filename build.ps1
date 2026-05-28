param(
    [string]$Platform,
    [string]$Targets,
    [string]$Version
)

$ErrorActionPreference = "Stop"

# Extract version from Directory.Build.props if not provided
if (-not $Version) {
    try {
        $buildProps = Get-Content "Directory.Build.props" -ErrorAction SilentlyContinue
        if ($buildProps) {
            $match = [regex]::Match($buildProps, '<InformationalVersion>([^<]+)</InformationalVersion>')
            if ($match.Success) {
                $Version = $match.Groups[1].Value
            }
        }
    } catch {
        $Version = $null
    }

    if (-not $Version) {
        Write-Host ""
        $Version = Read-Host "Enter Version (x.y.z or x.y.z-suffix)"
    }
}

# Append build number (git commit hash) for differentiation
try {
    $buildNumber = & git rev-parse --short HEAD
} catch {
    $buildNumber = "unknown"
}
$versionWithBuild = "$Version-$buildNumber"

# Prompt for platforms if not provided
if (-not $Platform) {
    Write-Host ""
    Write-Host "Select platforms (comma-separated or 'all'): [all]"
    Write-Host "  - windows"
    Write-Host "  - linux"
    Write-Host "  - macos       (macOS Intel x64)"
    Write-Host "  - macos-arm   (macOS Apple Silicon)"
    $Platform = Read-Host "Platforms"
    if (-not $Platform) { $Platform = "all" }
}

# Prompt for targets if not provided
if (-not $Targets) {
    Write-Host ""
    Write-Host "Select targets (comma-separated or 'all'): [all]"
    Write-Host "  - client"
    Write-Host "  - server"
    $Targets = Read-Host "Targets"
    if (-not $Targets) { $Targets = "all" }
}

# Normalize inputs to lowercase and trim
$Platform = $Platform.ToLower().Trim()
$Targets = $Targets.ToLower().Trim()

# Expand "all" to full list
if ($Platform -eq "all") {
    $PlatformList = @("windows", "linux", "macos", "macos-arm")
} else {
    $PlatformList = @($Platform -split "," | ForEach-Object { $_.Trim() })
}

if ($Targets -eq "all") {
    $TargetList = @("client", "server")
} else {
    $TargetList = @($Targets -split "," | ForEach-Object { $_.Trim() })
}

# Validate platforms and targets
$validPlatforms = @("windows", "linux", "macos", "macos-arm")
$validTargets = @("client", "server")

foreach ($p in $PlatformList) {
    if ($validPlatforms -notcontains $p) {
        Write-Host "Error: Invalid platform '$p'" -ForegroundColor Red
        exit 1
    }
}

foreach ($t in $TargetList) {
    if ($validTargets -notcontains $t) {
        Write-Host "Error: Invalid target '$t'" -ForegroundColor Red
        exit 1
    }
}

# Map platforms to RIDs
$platformConfig = @{
    "windows"    = "win-x64"
    "linux"      = "linux-x64"
    "macos"      = "osx-x64"
    "macos-arm"  = "osx-arm64"
}

# Convert RID to display name (osx-* becomes macos-*)
function Get-DisplayName {
    param([string]$RID)
    return $RID -replace '^osx-', 'macos-'
}

# Create releases directory
if (-not (Test-Path "Releases")) {
    New-Item -ItemType Directory -Path "Releases" | Out-Null
}

# Create version-specific release directory
$releaseDir = "Releases/BlendFarm-Neo-$versionWithBuild"
if (-not (Test-Path $releaseDir)) {
    New-Item -ItemType Directory -Path $releaseDir | Out-Null
}

# Clean up old build artifacts
if (Test-Path "_Build" -PathType Container) {
    Remove-Item "_Build" -Recurse -Force -ErrorAction Stop
}

Write-Host ""
Write-Host "========== BlendFarm Neo Build Configuration ==========" -ForegroundColor Cyan
Write-Host "Version:  $versionWithBuild"
Write-Host "Platforms: $($PlatformList -join ',')"
Write-Host "Targets:   $($TargetList -join ',')"
Write-Host ""

# Function to build a component for a platform
function Build-Component {
    param(
        [string]$Component,
        [string]$Platform,
        [string]$RID,
        [string]$Framework = "net8.0"
    )

    $project = if ($Component -eq "server") { "LogicReinc.BlendFarm.Server" } else { "LogicReinc.BlendFarm" }

    Write-Host "========== Building $Component ($RID) ==========" -ForegroundColor Green
    & dotnet publish $project -f $Framework -c Release -r $RID `
        -p:PublishSingleFile=true `
        -p:PublishReadyToRunShowWarnings=false `
        --self-contained $true `
        -o "_Build/$Component/$RID"
    Write-Host ""
}

# Function to package a build
function Package-Build {
    param(
        [string]$Component,
        [string]$Platform,
        [string]$RID,
        [string]$ExeName
    )

    $capitalComponent = (Get-Culture).TextInfo.ToTitleCase($Component)
    $displayRID = Get-DisplayName $RID

    $pkgName = "BlendFarm-Neo-$versionWithBuild-$capitalComponent-$displayRID"
    $pkgDir = "Releases/BlendFarm-Neo-$versionWithBuild/$pkgName"

    # Validate variables before deletion
    if ([string]::IsNullOrEmpty($pkgName) -or [string]::IsNullOrEmpty($pkgDir)) {
        Write-Host "Error: Package name or package directory is undefined" -ForegroundColor Red
        return
    }

    # Clean up existing package (with path validation)
    if (Test-Path $pkgDir -PathType Container) {
        Remove-Item $pkgDir -Recurse -Force -ErrorAction Stop
    }
    if (Test-Path "$pkgDir.zip" -PathType Leaf) {
        Remove-Item "$pkgDir.zip" -Force -ErrorAction Stop
    }

    New-Item -ItemType Directory -Path $pkgDir -Force | Out-Null
    Copy-Item "_Build/$Component/$RID/$ExeName" "$pkgDir/"

    Push-Location "Releases/BlendFarm-Neo-$versionWithBuild"
    Compress-Archive -Path $pkgName -DestinationPath "$pkgName.zip" -Force
    Pop-Location

    Write-Host "Packaged: BlendFarm-Neo-$versionWithBuild/$pkgName.zip"
}

# Function to package macOS ARM64 with .app bundle
function Package-MacOSArm {
    param(
        [string]$Component
    )

    Write-Host "========== Packaging $Component macOS ARM64 (.app bundle) ==========" -ForegroundColor Green

    $capitalComponent = (Get-Culture).TextInfo.ToTitleCase($Component)
    $pkgName = "BlendFarm-Neo-$versionWithBuild-$capitalComponent-macos-arm64"
    $pkgDir = "Releases/BlendFarm-Neo-$versionWithBuild/$pkgName"
    $templatePath = "Deploy/LogicReinc.BlendFarm/_Resources/BlendFarm-___-OSX-ARM64"

    if (-not (Test-Path $templatePath)) {
        Write-Host "Error: macOS ARM64 template not found at $templatePath" -ForegroundColor Red
        Write-Host "       This is required for .app bundle packaging" -ForegroundColor Red
        return $false
    }

    # Validate variables before deletion
    if ([string]::IsNullOrEmpty($pkgName) -or [string]::IsNullOrEmpty($pkgDir)) {
        Write-Host "Error: Package name or package directory is undefined" -ForegroundColor Red
        return $false
    }

    # Clean up existing package (with path validation)
    if (Test-Path $pkgDir -PathType Container) {
        Remove-Item $pkgDir -Recurse -Force -ErrorAction Stop
    }
    if (Test-Path "$pkgDir.zip" -PathType Leaf) {
        Remove-Item "$pkgDir.zip" -Force -ErrorAction Stop
    }

    New-Item -ItemType Directory -Path $pkgDir -Force | Out-Null
    Copy-Item "$templatePath/LogicReinc.BlendFarm.app" -Destination $pkgDir -Recurse -Force
    Copy-Item "_Build/$Component/osx-arm64/LogicReinc.BlendFarm" `
        "$pkgDir/LogicReinc.BlendFarm.app/Contents/MacOS/LogicReinc.BlendFarm"

    $plistPath = "$pkgDir/LogicReinc.BlendFarm.app/Contents/Info.plist"
    $plistContent = Get-Content $plistPath -Raw
    $plistContent = $plistContent -replace "1.0.3", $version
    Set-Content $plistPath $plistContent

    Get-ChildItem "_Build/$Component/osx-arm64/" -Filter "*.dylib" | ForEach-Object {
        Copy-Item $_.FullName "$pkgDir/LogicReinc.BlendFarm.app/Contents/MacOS/"
    }

    Push-Location "Releases/BlendFarm-Neo-$versionWithBuild"
    Compress-Archive -Path $pkgName -DestinationPath "$pkgName.zip" -Force
    Pop-Location

    Write-Host "Packaged: BlendFarm-Neo-$versionWithBuild/$pkgName.zip"
    return $true
}

# Build and package
foreach ($platform in $PlatformList) {
    $rid = $platformConfig[$platform]

    if (-not $rid) {
        Write-Host "Error: Unknown platform '$platform'" -ForegroundColor Red
        exit 1
    }

    foreach ($target in $TargetList) {
        # Build
        Build-Component -Component $target -Platform $platform -RID $rid

        # Determine executable name
        $exeName = if ($target -eq "server") {
            if ($platform -eq "windows") { "LogicReinc.BlendFarm.Server.exe" } else { "LogicReinc.BlendFarm.Server" }
        } else {
            if ($platform -eq "windows") { "LogicReinc.BlendFarm.exe" } else { "LogicReinc.BlendFarm" }
        }

        # Package based on platform
        if ($platform -eq "macos-arm" -and $target -eq "client") {
            $result = Package-MacOSArm -Component $target
            if (-not $result) { exit 1 }
        } else {
            Package-Build -Component $target -Platform $platform -RID $rid -ExeName $exeName
        }
    }
}

# Cleanup build artifacts (with validation)
if (Test-Path "_Build" -PathType Container) {
    Remove-Item "_Build" -Recurse -Force -ErrorAction Stop
}

Write-Host ""
Write-Host "========== BUILD COMPLETE ==========" -ForegroundColor Cyan
Write-Host "Release packages ready in ./Releases/BlendFarm-Neo-$versionWithBuild/" -ForegroundColor Green
Write-Host ""

$releaseDir = "Releases/BlendFarm-Neo-$versionWithBuild"
if (Test-Path $releaseDir) {
    Get-ChildItem "$releaseDir/*.zip" | ForEach-Object {
        $sizeMB = [Math]::Round($_.Length / 1MB, 2)
        Write-Host "  $($_.Name) ($sizeMB MB)" -ForegroundColor Gray
    }
}
