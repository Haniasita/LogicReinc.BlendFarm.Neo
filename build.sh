#!/bin/bash

set -e

# Parse command line arguments
RUN_TESTS=false
CLEAN_BLENDER=false
while [[ $# -gt 0 ]]; do
  case $1 in
    --platform) PLATFORM="$2"; shift 2 ;;
    --targets) TARGETS="$2"; shift 2 ;;
    --version) version="$2"; shift 2 ;;
    --run-tests) RUN_TESTS=true; shift ;;
    --clean-blender) CLEAN_BLENDER=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Extract version from Directory.Build.props if not provided
if [ -z "$version" ]; then
  version=$(grep -oP '<InformationalVersion>\K[^<]+' "Directory.Build.props" 2>/dev/null || true)

  if [ -z "$version" ]; then
    echo ""
    echo "Enter Version (x.y.z or x.y.z-suffix)"
    read version
  fi
fi

# Append build number (git commit hash) for differentiation
build_number=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
version_with_build="${version}-${build_number}"

# Prompt for platforms if not provided
if [ -z "$PLATFORM" ]; then
  echo ""
  echo "Select platforms (comma-separated or 'all'): [all]"
  echo "  - windows"
  echo "  - linux"
  echo "  - macos       (macOS Intel x64)"
  echo "  - macos-arm   (macOS Apple Silicon)"
  read -p "Platforms: " PLATFORM
  PLATFORM=${PLATFORM:-all}
fi

# Prompt for targets if not provided
if [ -z "$TARGETS" ]; then
  echo ""
  echo "Select targets (comma-separated or 'all'): [all]"
  echo "  - client"
  echo "  - server"
  read -p "Targets: " TARGETS
  TARGETS=${TARGETS:-all}
fi

# Normalize inputs to lowercase
PLATFORM=$(echo "$PLATFORM" | tr '[:upper:]' '[:lower:]' | xargs)
TARGETS=$(echo "$TARGETS" | tr '[:upper:]' '[:lower:]' | xargs)

# Expand "all" to full list
if [ "$PLATFORM" = "all" ]; then
  PLATFORMS=("windows" "linux" "macos" "macos-arm")
else
  IFS=',' read -ra PLATFORMS <<< "$PLATFORM"
fi

if [ "$TARGETS" = "all" ]; then
  BUILD_TARGETS=("client" "server")
else
  IFS=',' read -ra BUILD_TARGETS <<< "$TARGETS"
fi

# Validate platforms and targets
for p in "${PLATFORMS[@]}"; do
  p=$(echo "$p" | xargs)
  if [[ ! " windows linux macos macos-arm " =~ " $p " ]]; then
    echo "Error: Invalid platform '$p'"
    exit 1
  fi
done

for t in "${BUILD_TARGETS[@]}"; do
  t=$(echo "$t" | xargs)
  if [[ ! " client server " =~ " $t " ]]; then
    echo "Error: Invalid target '$t'"
    exit 1
  fi
done

# Map platforms to RIDs
declare -A platform_config
platform_config[windows]="win-x64"
platform_config[linux]="linux-x64"
platform_config[macos]="osx-x64"
platform_config[macos-arm]="osx-arm64"

# Convert RID to display name (osx-* becomes macos-*)
get_display_name() {
  echo "$1" | sed 's/^osx-/macos-/'
}

# Create releases directory
mkdir -p "Releases/BlendFarm-Neo-$version_with_build"

# Clean up old build artifacts
if [ -d "_Build" ]; then
  rm -rf "_Build"
fi

echo ""
echo "========== BlendFarm Neo Build Configuration =========="
echo "Version:  $version_with_build"
echo "Platforms: $(IFS=,; echo "${PLATFORMS[*]}")"
echo "Targets:   $(IFS=,; echo "${BUILD_TARGETS[*]}")"
echo ""

# Run tests
echo "========== Running Tests =========="
echo "Running ParsingTest (fast unit tests)..."
if ! dotnet test LogicReinc.BlendFarm.Tests/LogicReinc.BlendFarm.Tests.csproj \
  --filter "ClassName=ParsingTest" -c Release --no-build; then
  echo "Error: Unit tests failed" >&2
  exit 1
fi

if [ "$RUN_TESTS" = true ]; then
  echo ""
  echo "Running full integration tests (requires Blender)..."
  if ! dotnet test LogicReinc.BlendFarm.Tests/LogicReinc.BlendFarm.Tests.csproj \
    -c Release --no-build; then
    echo "Error: Integration tests failed" >&2
    exit 1
  fi
fi

if [ "$CLEAN_BLENDER" = true ]; then
  echo ""
  echo "Cleaning up Blender cache..."
  if [ -d "BlenderData" ]; then
    rm -rf "BlenderData"
    echo "Blender cache removed"
  fi
fi

echo ""

# Function to build a component for a platform
build_component() {
  local component=$1
  local platform=$2
  local rid=$3
  local framework="net8.0"

  local project="LogicReinc.BlendFarm"

  if [ "$component" = "server" ]; then
    project="LogicReinc.BlendFarm.Server"
  fi

  echo "========== Building $component ($rid) =========="
  dotnet publish "$project" -f "$framework" -c Release -r "$rid" \
    -p:PublishSingleFile=true \
    -p:PublishReadyToRunShowWarnings=false \
    --self-contained true \
    -o "_Build/${component}/${rid}"
  echo ""
}

# Function to package a build
package_build() {
  local component=$1
  local platform=$2
  local rid=$3
  local exe_name=$4

  local display_rid=$(get_display_name "$rid")
  local pkg_name="BlendFarm-Neo-$version_with_build-$(capitalize_first $component)-$display_rid"
  local pkg_dir="Releases/BlendFarm-Neo-$version_with_build/$pkg_name"
  local release_base="Releases/BlendFarm-Neo-$version_with_build"

  # Validate variables before deletion
  if [ -z "$pkg_name" ] || [ -z "$release_base" ]; then
    echo "Error: Package name or release directory is undefined"
    return 1
  fi

  # Clean up existing package
  if [ -d "$pkg_dir" ]; then
    rm -rf "$pkg_dir"
  fi
  if [ -f "$release_base/$pkg_name.zip" ]; then
    rm -f "$release_base/$pkg_name.zip"
  fi

  mkdir -p "$pkg_dir"
  cp "_Build/${component}/${rid}/$exe_name" "$pkg_dir/"

  cd "Releases/BlendFarm-Neo-$version_with_build"
  zip -q -r "${pkg_name}.zip" "$pkg_name"
  cd ../..

  echo "Packaged: BlendFarm-Neo-$version_with_build/${pkg_name}.zip"
}

# Function to package macOS ARM64 with .app bundle
package_macos_arm() {
  local component=$1

  local pkg_name="BlendFarm-Neo-$version_with_build-$(capitalize_first $component)-macos-arm64"
  local pkg_dir="Releases/BlendFarm-Neo-$version_with_build/$pkg_name"
  local release_base="Releases/BlendFarm-Neo-$version_with_build"

  # Preserve the Deploy structure for .app bundle
  if [ ! -d "Deploy/LogicReinc.BlendFarm/_Resources/BlendFarm-___-OSX-ARM64" ]; then
    echo "Error: macOS ARM64 template not found at Deploy/LogicReinc.BlendFarm/_Resources/BlendFarm-___-OSX-ARM64"
    echo "       This is required for .app bundle packaging"
    return 1
  fi

  # Validate variables before deletion
  if [ -z "$pkg_name" ] || [ -z "$release_base" ]; then
    echo "Error: Package name or release directory is undefined"
    return 1
  fi

  # Clean up existing package (with path validation)
  if [ -d "$pkg_dir" ]; then
    rm -rf "$pkg_dir"
  fi
  if [ -f "$release_base/$pkg_name.zip" ]; then
    rm -f "$release_base/$pkg_name.zip"
  fi

  mkdir -p "$pkg_dir"
  cp "Deploy/LogicReinc.BlendFarm/_Resources/BlendFarm-___-OSX-ARM64/LogicReinc.BlendFarm.app" -R "$pkg_dir/"
  cp "_Build/${component}/osx-arm64/LogicReinc.BlendFarm" "$pkg_dir/LogicReinc.BlendFarm.app/Contents/MacOS/LogicReinc.BlendFarm"
  sed -i "s/1.0.3/$version/" "$pkg_dir/LogicReinc.BlendFarm.app/Contents/Info.plist"
  find "_Build/${component}/osx-arm64/" -name "*.dylib" -exec cp {} "$pkg_dir/LogicReinc.BlendFarm.app/Contents/MacOS/" \;

  cd "Releases/BlendFarm-Neo-$version_with_build"
  zip -q -r "${pkg_name}.zip" "$pkg_name"
  cd ../..

  echo "Packaged: BlendFarm-Neo-$version_with_build/${pkg_name}.zip"
}

# Helper function to capitalize first letter
capitalize_first() {
  echo "$1" | sed 's/^\(.\)/\U\1/'
}

# Build all components
for platform in "${PLATFORMS[@]}"; do
  platform=$(echo "$platform" | xargs)
  rid="${platform_config[$platform]}"

  if [ -z "$rid" ]; then
    echo "Error: Unknown platform '$platform'"
    exit 1
  fi

  for target in "${BUILD_TARGETS[@]}"; do
    target=$(echo "$target" | xargs)
    build_component "$target" "$platform" "$rid"
  done
done

# Package all components
for platform in "${PLATFORMS[@]}"; do
  platform=$(echo "$platform" | xargs)
  rid="${platform_config[$platform]}"

  for target in "${BUILD_TARGETS[@]}"; do
    target=$(echo "$target" | xargs)

    # Determine executable name
    if [ "$target" = "server" ]; then
      if [ "$platform" = "windows" ]; then
        exe_name="LogicReinc.BlendFarm.Server.exe"
      else
        exe_name="LogicReinc.BlendFarm.Server"
      fi
    else
      if [ "$platform" = "windows" ]; then
        exe_name="LogicReinc.BlendFarm.exe"
      else
        exe_name="LogicReinc.BlendFarm"
      fi
    fi

    # Package based on platform
    if [ "$platform" = "macos-arm" ] && [ "$target" = "client" ]; then
      package_macos_arm "$target"
    else
      package_build "$target" "$platform" "$rid" "$exe_name"
    fi
  done
done

# Cleanup build artifacts
if [ -d "_Build" ]; then
  rm -rf "_Build"
fi

echo ""
echo "========== BUILD COMPLETE =========="
echo "Release packages ready in ./Releases/BlendFarm-Neo-$version_with_build/"
echo ""
