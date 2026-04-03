#!/bin/bash
set -e

# 1. Fetch the absolute latest Core tag
LATEST_TAG=$(curl -s https://api.github.com/repos/nymtech/nym-vpn-client/releases | \
             grep -o "nym-vpn-core-v[0-9]*\.[0-9]*\.[0-9]*" | \
             sort -Vr | \
             head -n 1)

# Strip the prefix to get just the version number (e.g., 1.25.0)
NYM_VERSION=${LATEST_TAG#nym-vpn-core-v}

echo "Installing NymVPN Daemon version: ${NYM_VERSION}"

# 2. Define URLs
BIN_URL="https://github.com/nymtech/nym-vpn-client/releases/download/${LATEST_TAG}/nym-vpn-core-v${NYM_VERSION}_linux_x86_64.tar.gz"
UNIT_URL="https://raw.githubusercontent.com/nymtech/nym-vpn-client/refs/tags/${LATEST_TAG}/nym-vpn-core/crates/nym-vpnd/linux/unit-scripts/nym-vpnd.service"

# 3. Setup workspace
TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"

# 4. Download and Install the Binary
echo "Downloading and extracting binary..."
curl -sSL "$BIN_URL" | tar -xz
# Ensure the directory exists (The archive structure can sometimes vary)
install -Dm755 $(find . -name "nym-vpnd" -type f) /usr/bin/nym-vpnd

# 5. Download and Install the Service Unit
echo "Configuring Systemd Unit..."
curl -sSL "$UNIT_URL" -o nym-vpnd.service
install -Dm644 nym-vpnd.service /usr/lib/systemd/system/nym-vpnd.service

# 6. Prepare Config Directory
# The daemon will likely crash on first boot if this doesn't exist
mkdir -p /etc/nym/

# 7. Enable the Service
systemctl enable nym-vpnd.service

# 8. Cleanup
rm -rf "$TEMP_DIR"

echo "Installation complete."