#!/bin/bash
set -e

# =========================
# Configuration
# =========================
TARGET="$1"  # Optional: stable | latest | VERSION

INSTALL_ROOT="/opt/claude"
BIN_DIR="$INSTALL_ROOT/bin"
CURRENT_LINK="$INSTALL_ROOT/current"
SYMLINK="/usr/local/bin/claude"

GCS_BUCKET="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"
TMP_DIR="$(mktemp -d)"

# =========================
# Validate target
# =========================
if [[ -n "$TARGET" ]] && [[ ! "$TARGET" =~ ^(stable|latest|[0-9]+\.[0-9]+\.[0-9]+(-[^[:space:]]+)?)$ ]]; then
    echo "Usage: $0 [stable|latest|VERSION]" >&2
    exit 1
fi

# =========================
# Dependencies
# =========================
DOWNLOADER=""
if command -v curl >/dev/null 2>&1; then
    DOWNLOADER="curl"
elif command -v wget >/dev/null 2>&1; then
    DOWNLOADER="wget"
else
    echo "Either curl or wget is required" >&2
    exit 1
fi

HAS_JQ=false
if command -v jq >/dev/null 2>&1; then
    HAS_JQ=true
fi

download_file() {
    local url="$1"
    local output="$2"

    if [ "$DOWNLOADER" = "curl" ]; then
        curl -fsSL -o "$output" "$url"
    else
        wget -q -O "$output" "$url"
    fi
}

get_checksum_from_manifest() {
    local json="$1"
    local platform="$2"

    json=$(echo "$json" | tr -d '\n\r\t' | sed 's/ \+/ /g')

    if [[ $json =~ \"$platform\"[^}]*\"checksum\"[[:space:]]*:[[:space:]]*\"([a-f0-9]{64})\" ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi

    return 1
}

# =========================
# Platform Detection
# =========================
case "$(uname -s)" in
    Darwin) os="darwin" ;;
    Linux) os="linux" ;;
    *) echo "Unsupported OS" >&2; exit 1 ;;
esac

case "$(uname -m)" in
    x86_64|amd64) arch="x64" ;;
    arm64|aarch64) arch="arm64" ;;
    *) echo "Unsupported architecture" >&2; exit 1 ;;
esac

if [ "$os" = "linux" ]; then
    if ldd /bin/ls 2>&1 | grep -q musl; then
        platform="linux-${arch}-musl"
    else
        platform="linux-${arch}"
    fi
else
    platform="${os}-${arch}"
fi

# =========================
# Resolve Latest Stable
# =========================
echo "Fetching latest stable Claude Code version..."
version_file="$TMP_DIR/version"
download_file "$GCS_BUCKET/stable" "$version_file"
version="$(cat "$version_file")"

# =========================
# Fetch Manifest & Checksum
# =========================
manifest_file="$TMP_DIR/manifest.json"
download_file "$GCS_BUCKET/$version/manifest.json" "$manifest_file"
manifest_json="$(cat "$manifest_file")"

if [ "$HAS_JQ" = true ]; then
    checksum=$(echo "$manifest_json" | jq -r ".platforms[\"$platform\"].checksum // empty")
else
    checksum=$(get_checksum_from_manifest "$manifest_json" "$platform")
fi

if [ -z "$checksum" ] || [[ ! "$checksum" =~ ^[a-f0-9]{64}$ ]]; then
    echo "Platform $platform not found in manifest" >&2
    exit 1
fi

# =========================
# Download Binary
# =========================
binary_tmp="$TMP_DIR/claude"
echo "Downloading Claude Code $version for $platform..."
download_file "$GCS_BUCKET/$version/$platform/claude" "$binary_tmp"

# =========================
# Verify Checksum
# =========================
if [ "$os" = "darwin" ]; then
    actual=$(shasum -a 256 "$binary_tmp" | cut -d' ' -f1)
else
    actual=$(sha256sum "$binary_tmp" | cut -d' ' -f1)
fi

if [ "$actual" != "$checksum" ]; then
    echo "Checksum verification failed" >&2
    exit 1
fi

chmod +x "$binary_tmp"

# =========================
# Install Into /opt
# =========================
echo "Installing Claude Code to $INSTALL_ROOT..."
mkdir -p "$BIN_DIR"

install_path="$BIN_DIR/claude-$version"
mv "$binary_tmp" "$install_path"
chmod 755 "$install_path"

# Update "current" symlink
ln -sfn "$install_path" "$CURRENT_LINK"

# Create launcher symlink
ln -sfn "$CURRENT_LINK" "$SYMLINK"

# =========================
# Run Claude Setup
# =========================
echo "Setting up Claude Code shell integration..."
"$SYMLINK" install ${TARGET:+"$TARGET"}

# =========================
# Cleanup
# =========================
rm -rf "$TMP_DIR"

echo ""
echo "✅ Claude Code installed successfully!"
echo "   Binary:   $SYMLINK"
echo "   Versions: $BIN_DIR"
echo ""
