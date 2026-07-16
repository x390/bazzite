#!/bin/bash
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "This script needs root (for the daemon and system-wide app install)." >&2
  exit 1
fi

# --- Resolve latest stable release ---
REL_JSON=$(curl -fsSL "https://api.github.com/repos/nymtech/nym-vpn-client/releases?per_page=100" \
  | jq '[.[] | select(.draft==false and .prerelease==false)]
        | map(select(.assets[].name | test("nym-vpn-core-v.*_linux_x86_64\\.tar\\.gz$")))
        | .[0]')

if [ "$REL_JSON" == "null" ]; then
  echo "Could not find a matching release" >&2
  exit 1
fi

LATEST_TAG=$(echo "$REL_JSON" | jq -r '.tag_name')
CORE_URL=$(echo "$REL_JSON" | jq -r '.assets[] | select(.name | test("nym-vpn-core-v.*_linux_x86_64\\.tar\\.gz$")) | .browser_download_url')
NYM_VERSION=$(basename "$CORE_URL" | sed -E 's/nym-vpn-core-v(.*)_linux_x86_64\.tar\.gz/\1/')
APP_IMAGE_URL=$(echo "$REL_JSON" | jq -r '.assets[] | select(.name | test("\\.AppImage$")) | .browser_download_url' | head -n1)

echo "Daemon version: ${NYM_VERSION} (tag: ${LATEST_TAG})"
[ -n "$APP_IMAGE_URL" ] && echo "App AppImage: $(basename "$APP_IMAGE_URL")" || echo "Warning: no AppImage asset found in this release" >&2

TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"

# --- Daemon ---
curl -sSL "$CORE_URL" | tar -xz
install -Dm755 "$(find . -name "nym-vpnd" -type f)" /usr/local/bin/nym-vpnd
command -v restorecon >/dev/null 2>&1 && restorecon -v /usr/local/bin/nym-vpnd

UNIT_URL="https://raw.githubusercontent.com/nymtech/nym-vpn-client/refs/tags/${LATEST_TAG}/nym-vpn-core/crates/nym-vpnd/linux/unit-scripts/nym-vpnd.service"
curl -sSL "$UNIT_URL" -o nym-vpnd.service
sed -i 's|/usr/bin/nym-vpnd|/usr/local/bin/nym-vpnd|' nym-vpnd.service
install -Dm644 nym-vpnd.service /etc/systemd/system/nym-vpnd.service

mkdir -p /etc/nym/
systemctl daemon-reload
systemctl enable --now nym-vpnd.service

# --- App ---
if [ -n "$APP_IMAGE_URL" ]; then
  curl -sSL "$APP_IMAGE_URL" -o NymVPN.AppImage
  chmod +x NymVPN.AppImage

  install -Dm755 NymVPN.AppImage /usr/local/bin/NymVPN.AppImage
  command -v restorecon >/dev/null 2>&1 && restorecon -v /usr/local/bin/NymVPN.AppImage
  ln -sf /usr/local/bin/NymVPN.AppImage /usr/local/bin/nym-vpn-app
  echo "App installed to /usr/local/bin/NymVPN.AppImage (symlinked as nym-vpn-app)"

  # --- Extract the icon straight from the AppImage (no guessed URLs) ---
  ./NymVPN.AppImage --appimage-extract >/dev/null

  ICON_SRC=""
  ICON_SRC=$(find squashfs-root/usr/share/icons squashfs-root/usr/share/pixmaps \
              -type f \( -iname "*.png" -o -iname "*.svg" \) 2>/dev/null | sort -r | head -n1 || true)
  [ -z "$ICON_SRC" ] && [ -f squashfs-root/.DirIcon ] && ICON_SRC="squashfs-root/.DirIcon"

  ICON_NAME="net.nymtech.vpn"
  if [ -n "$ICON_SRC" ]; then
    EXT="${ICON_SRC##*.}"
    case "$EXT" in
      svg) ICON_DEST="/usr/local/share/icons/hicolor/scalable/apps/${ICON_NAME}.svg" ;;
      *)   ICON_DEST="/usr/local/share/icons/hicolor/256x256/apps/${ICON_NAME}.png" ;;
    esac
    install -Dm644 "$ICON_SRC" "$ICON_DEST"
    command -v gtk-update-icon-cache >/dev/null 2>&1 && \
      gtk-update-icon-cache -f /usr/local/share/icons/hicolor 2>/dev/null || true
    echo "Icon installed to ${ICON_DEST}"
  else
    echo "Warning: no icon found inside the AppImage, launcher entry will use a generic icon" >&2
  fi

  # --- Desktop entry ---
  install -Dm644 /dev/stdin /usr/local/share/applications/net.nymtech.vpn.desktop <<EOF
[Desktop Entry]
Type=Application
Name=NymVPN
Comment=Decentralized, mixnet and zero-knowledge VPN
Exec=/usr/local/bin/NymVPN.AppImage
Icon=${ICON_NAME}
Terminal=false
Categories=Network;Security;
StartupWMClass=nym-vpn-app
EOF

  update-desktop-database /usr/local/share/applications 2>/dev/null || true
  echo "Desktop entry installed to /usr/local/share/applications/net.nymtech.vpn.desktop"
else
  echo "Warning: no app asset found in this release" >&2
fi

rm -rf "$TEMP_DIR"
echo "Installation complete. Any user can now run 'nym-vpn-app'."
