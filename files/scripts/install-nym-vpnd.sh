#!/bin/bash
set -euo pipefail

# Optional GitHub token to avoid CI rate limits (pass GITHUB_TOKEN into the build env)
AUTH_ARGS=()
[ -n "${GITHUB_TOKEN:-}" ] && AUTH_ARGS=(-H "Authorization: Bearer ${GITHUB_TOKEN}")

RELEASES_JSON=$(curl -fsSL "${AUTH_ARGS[@]}" \
  "https://api.github.com/repos/nymtech/nym-vpn-client/releases?per_page=100")

# --- Resolve latest stable release containing the Linux x86_64 core tarball ---
CORE_RE='nym-vpn-core-v.*_linux_x86_64\\.tar\\.gz$'
CORE_REL_JSON=$(echo "$RELEASES_JSON" \
  | jq --arg re "$CORE_RE" '[.[] | select(.draft==false and .prerelease==false)]
        | map(select(.assets[].name | test($re))) | .[0]')

if [ "$CORE_REL_JSON" == "null" ]; then
  echo "Could not find a release with a Linux core tarball" >&2
  exit 1
fi

LATEST_TAG=$(echo "$CORE_REL_JSON" | jq -r '.tag_name')
CORE_URL=$(echo "$CORE_REL_JSON" | jq -r --arg re "$CORE_RE" \
  '.assets[] | select(.name | test($re)) | .browser_download_url' | head -n1)
NYM_VERSION=$(basename "$CORE_URL" | sed -E 's/nym-vpn-core-v(.*)_linux_x86_64\.tar\.gz/\1/')

# --- Resolve latest stable release containing an x86_64 AppImage (independently; arch-filtered) ---
APP_RE='(x64|amd64|x86_64)[^/]*\\.AppImage$'
APP_REL_JSON=$(echo "$RELEASES_JSON" \
  | jq --arg re "$APP_RE" '[.[] | select(.draft==false and .prerelease==false)]
        | map(select(.assets[].name | test($re))) | .[0]')

APP_IMAGE_URL=""
if [ "$APP_REL_JSON" != "null" ]; then
  APP_IMAGE_URL=$(echo "$APP_REL_JSON" | jq -r --arg re "$APP_RE" \
    '.assets[] | select(.name | test($re)) | .browser_download_url' | head -n1)
fi

echo "Daemon version: ${NYM_VERSION} (tag: ${LATEST_TAG})"
[ -n "$APP_IMAGE_URL" ] && echo "App AppImage: $(basename "$APP_IMAGE_URL")" \
  || echo "Warning: no x86_64 AppImage found in any recent stable release" >&2

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT
cd "$TEMP_DIR"

# --- Daemon ---
# Build-time image context: /usr IS writable here, and /usr/local is a symlink
# into /var on ostree images, so /var content would be DROPPED from the final
# image. Everything goes under /usr proper.
curl -fsSL "$CORE_URL" | tar -xz
install -Dm755 "$(find . -name "nym-vpnd" -type f | head -n1)" /usr/bin/nym-vpnd

UNIT_URL="https://raw.githubusercontent.com/nymtech/nym-vpn-client/refs/tags/${LATEST_TAG}/nym-vpn-core/crates/nym-vpnd/linux/unit-scripts/nym-vpnd.service"
curl -fsSL "$UNIT_URL" -o nym-vpnd.service

# Normalize in case upstream unit points at /usr/local, then sanity-check
sed -i 's|/usr/local/bin/nym-vpnd|/usr/bin/nym-vpnd|' nym-vpnd.service
grep -q '^ExecStart=.*nym-vpnd' nym-vpnd.service || {
  echo "Downloaded unit file doesn't look like a valid nym-vpnd unit:" >&2
  cat nym-vpnd.service >&2
  exit 1
}
install -Dm644 nym-vpnd.service /usr/lib/systemd/system/nym-vpnd.service

mkdir -p /etc/nym/

# Offline enable: writes the wants/ symlink directly, no live systemd/D-Bus needed
systemctl enable --root=/ nym-vpnd.service

# --- App: AppImage, system-wide ---
if [ -n "$APP_IMAGE_URL" ]; then
  curl -fsSL "$APP_IMAGE_URL" -o NymVPN.AppImage
  chmod +x NymVPN.AppImage

  install -Dm755 NymVPN.AppImage /usr/bin/NymVPN.AppImage
  ln -sf /usr/bin/NymVPN.AppImage /usr/bin/nym-vpn-app
  echo "App installed to /usr/bin/NymVPN.AppImage (symlinked as nym-vpn-app)"

  # Extract icon straight from the AppImage (-L: icons are often internal symlinks)
  ./NymVPN.AppImage --appimage-extract >/dev/null

  ICON_SRC=$(find -L squashfs-root/usr/share/icons squashfs-root/usr/share/pixmaps \
              -type f \( -iname "*.png" -o -iname "*.svg" \) 2>/dev/null | sort -r | head -n1 || true)
  [ -z "$ICON_SRC" ] && [ -e squashfs-root/.DirIcon ] && ICON_SRC="squashfs-root/.DirIcon"

  ICON_NAME="net.nymtech.vpn"
  if [ -n "$ICON_SRC" ]; then
    EXT="${ICON_SRC##*.}"
    case "$EXT" in
      svg) ICON_DEST="/usr/share/icons/hicolor/scalable/apps/${ICON_NAME}.svg" ;;
      *)   ICON_DEST="/usr/share/icons/hicolor/256x256/apps/${ICON_NAME}.png" ;;
    esac
    install -Dm644 "$ICON_SRC" "$ICON_DEST"
    echo "Icon installed to ${ICON_DEST}"
  else
    echo "Warning: no icon found inside the AppImage, launcher entry will use a generic icon" >&2
  fi

  install -Dm644 /dev/stdin /usr/share/applications/net.nymtech.vpn.desktop <<EOF
[Desktop Entry]
Type=Application
Name=NymVPN
Comment=Decentralized, mixnet and zero-knowledge VPN
Exec=/usr/bin/NymVPN.AppImage
Icon=${ICON_NAME}
Terminal=false
Categories=Network;Security;
StartupWMClass=nym-vpn-app
EOF

  echo "Desktop entry installed to /usr/share/applications/net.nymtech.vpn.desktop"
else
  echo "Warning: no app asset found, skipping app install" >&2
fi

echo "Installation complete."
