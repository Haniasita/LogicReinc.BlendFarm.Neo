param(
    [string]$Platform,
    [string]$Targets,
    [string]$Version,
    [switch]$RunTests,
    [switch]$CleanBlender,
    [switch]$Zip
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

# Run tests
Write-Host "========== Running Tests ==========" -ForegroundColor Cyan
Write-Host "Running ParsingTest (fast unit tests)..."
& dotnet test "LogicReinc.BlendFarm.Tests/LogicReinc.BlendFarm.Tests.csproj" `
    --filter "ClassName=ParsingTest" -c Release --no-build
if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: Unit tests failed" -ForegroundColor Red
    exit 1
}

if ($RunTests) {
    Write-Host ""
    Write-Host "Running full integration tests (requires Blender)..."
    & dotnet test "LogicReinc.BlendFarm.Tests/LogicReinc.BlendFarm.Tests.csproj" `
        -c Release --no-build
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Error: Integration tests failed" -ForegroundColor Red
        exit 1
    }
}

if ($CleanBlender) {
    Write-Host ""
    Write-Host "Cleaning up Blender cache..."
    if (Test-Path "BlenderData" -PathType Container) {
        Remove-Item "BlenderData" -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Blender cache removed"
    }
}

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
        -p:IncludeNativeLibrariesForSelfExtract=true `
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
        [string]$ExeName,
        [bool]$CreateZip = $false
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

    # Copy only necessary files, excluding debug/utility files
    Get-ChildItem "_Build/$Component/$RID" | Where-Object {
        $name = $_.Name
        # Exclude: debug symbols, debug tools, python scripts, unnecessary files
        -not ($name -match '\.(pdb|dbg)$') -and
        -not ($name -match '(createdump|windbg)') -and
        -not ($name -match '\.(py|pyc)$')
    } | ForEach-Object {
        if ($_.PSIsContainer) {
            Copy-Item $_.FullName "$pkgDir/$($_.Name)" -Recurse
        } else {
            Copy-Item $_.FullName "$pkgDir/"
        }
    }

    # Bundle example configuration files
    if (Test-Path "ServerSettings.example") {
        Copy-Item "ServerSettings.example" "$pkgDir/"
    }
    if ($Component -eq "client" -and (Test-Path "ClientSettings.example")) {
        Copy-Item "ClientSettings.example" "$pkgDir/"
    }

    if ($CreateZip) {
        Push-Location "Releases/BlendFarm-Neo-$versionWithBuild"
        Compress-Archive -Path $pkgName -DestinationPath "$pkgName.zip" -Force
        Pop-Location

        Write-Host "Packaged: BlendFarm-Neo-$versionWithBuild/$pkgName.zip"
    } else {
        Write-Host "Built: BlendFarm-Neo-$versionWithBuild/$pkgName/"
    }
}

# Function to package macOS ARM64 with .app bundle
function Package-MacOSArm {
    param(
        [string]$Component,
        [bool]$CreateZip = $false
    )

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

    if ($CreateZip) {
        Push-Location "Releases/BlendFarm-Neo-$versionWithBuild"
        Compress-Archive -Path $pkgName -DestinationPath "$pkgName.zip" -Force
        Pop-Location

        Write-Host "Packaged: BlendFarm-Neo-$versionWithBuild/$pkgName.zip"
    } else {
        Write-Host "Built: BlendFarm-Neo-$versionWithBuild/$pkgName/"
    }
    return $true
}

# Build all components
foreach ($platform in $PlatformList) {
    $rid = $platformConfig[$platform]

    if (-not $rid) {
        Write-Host "Error: Unknown platform '$platform'" -ForegroundColor Red
        exit 1
    }

    foreach ($target in $TargetList) {
        Build-Component -Component $target -Platform $platform -RID $rid
    }
}

# Package all components
foreach ($platform in $PlatformList) {
    $rid = $platformConfig[$platform]

    foreach ($target in $TargetList) {
        # Determine executable name
        $exeName = if ($target -eq "server") {
            if ($platform -eq "windows") { "LogicReinc.BlendFarm.Server.exe" } else { "LogicReinc.BlendFarm.Server" }
        } else {
            if ($platform -eq "windows") { "LogicReinc.BlendFarm.exe" } else { "LogicReinc.BlendFarm" }
        }

        # Package based on platform
        if ($platform -eq "macos-arm" -and $target -eq "client") {
            $result = Package-MacOSArm -Component $target -CreateZip $Zip
            if (-not $result) { exit 1 }
        } else {
            Package-Build -Component $target -Platform $platform -RID $rid -ExeName $exeName -CreateZip $Zip
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
