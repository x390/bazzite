#!/bin/bash
set -euo pipefail

AUTH_ARGS=()
[ -n "${GITHUB_TOKEN:-}" ] && AUTH_ARGS=(-H "Authorization: Bearer ${GITHUB_TOKEN}")

RELEASES_JSON=$(curl -fsSL "${AUTH_ARGS[@]}" \
  "https://api.github.com/repos/nymtech/nym-vpn-client/releases?per_page=100")

# --- Resolve latest stable release containing the x86_64 core tarball ---
CORE_RE='nym-vpn-core-v.*_linux_x86_64\\.tar\\.gz$'
CORE_REL_JSON=$(echo "$RELEASES_JSON" | jq --arg re "$CORE_RE" \
  '[.[] | select(.draft==false and .prerelease==false)]
   | map(select(.assets[].name | test($re))) | .[0]')

[ "$CORE_REL_JSON" == "null" ] && { echo "No release with Linux core tarball" >&2; exit 1; }

CORE_TAG=$(echo "$CORE_REL_JSON" | jq -r '.tag_name')
CORE_URL=$(echo "$CORE_REL_JSON" | jq -r --arg re "$CORE_RE" \
  '.assets[] | select(.name | test($re)) | .browser_download_url' | head -n1)
CORE_ARCHIVE=$(basename "$CORE_URL")
NYM_VERSION=$(echo "$CORE_ARCHIVE" | sed -E 's/nym-vpn-core-v(.*)_linux_x86_64\.tar\.gz/\1/')

# --- Resolve latest stable release containing an x86_64 AppImage (independent) ---
APP_RE='(x64|amd64|x86_64)[^/]*\\.AppImage$'
APP_REL_JSON=$(echo "$RELEASES_JSON" | jq --arg re "$APP_RE" \
  '[.[] | select(.draft==false and .prerelease==false)]
   | map(select(.assets[].name | test($re))) | .[0]')

APP_URL="" APP_TAG=""
if [ "$APP_REL_JSON" != "null" ]; then
  APP_URL=$(echo "$APP_REL_JSON" | jq -r --arg re "$APP_RE" \
    '.assets[] | select(.name | test($re)) | .browser_download_url' | head -n1)
  APP_TAG=$(echo "$APP_REL_JSON" | jq -r '.tag_name')
fi

echo "Daemon: v${NYM_VERSION} (${CORE_TAG})"
[ -n "$APP_URL" ] && echo "App: $(basename "$APP_URL") (${APP_TAG})" \
  || echo "Warning: no x86_64 AppImage found" >&2

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT
cd "$TEMP_DIR"

# Download + verify sha256 (matches upstream pattern)
fetch_verified() {
  local url=$1 out=$2
  curl -fsSL "$url" -o "$out"
  curl -fsSL "$url.sha256sum" -o "$out.sha256sum"
  sha256sum --check --status "$out.sha256sum"
}

# --- Daemon: core tarball ships nym-vpnd AND nym-socks5-proxy ---
echo "Downloading core archive..."
fetch_verified "$CORE_URL" "$CORE_ARCHIVE"
tar -xzf "$CORE_ARCHIVE"
CORE_DIR="${CORE_ARCHIVE%.tar.gz}"

install -Dm755 "$CORE_DIR/nym-vpnd"         /usr/bin/nym-vpnd
install -Dm755 "$CORE_DIR/nym-socks5-proxy" /usr/bin/nym-socks5-proxy

# --- Unit file: path is .pkg/aur/nym-vpnd.service (per upstream installer) ---
UNIT_URL="https://raw.githubusercontent.com/nymtech/nym-vpn-client/refs/tags/${CORE_TAG}/nym-vpn-core/crates/nym-vpnd/.pkg/aur/nym-vpnd.service"
curl -fsSL "$UNIT_URL" -o nym-vpnd.service
grep -q '^ExecStart=.*nym-vpnd' nym-vpnd.service || {
  echo "Downloaded unit doesn't look valid:" >&2; cat nym-vpnd.service >&2; exit 1;
}
install -Dm644 nym-vpnd.service /usr/lib/systemd/system/nym-vpnd.service

mkdir -p /etc/nym/

# Offline enable — writes wants/ symlink directly, no live systemd required
systemctl enable --root=/ nym-vpnd.service

# --- App ---
if [ -n "$APP_URL" ]; then
  APP_FILE=$(basename "$APP_URL")
  echo "Downloading AppImage..."
  fetch_verified "$APP_URL" "$APP_FILE"

  install -Dm755 "$APP_FILE" /usr/bin/NymVPN.AppImage
  ln -sf /usr/bin/NymVPN.AppImage /usr/bin/nym-vpn-app

  # Desktop + icon: canonical URLs used by upstream installer
  DESKTOP_URL="https://raw.githubusercontent.com/nymtech/nym-vpn-client/refs/tags/${APP_TAG}/nym-vpn-app/.pkg/app.desktop"
  ICON_URL="https://raw.githubusercontent.com/nymtech/nym-vpn-client/refs/tags/${APP_TAG}/nym-vpn-app/.pkg/icon.svg"

  if curl -fsSL "$DESKTOP_URL" -o app.desktop; then
    # Rewrite Exec to installed path, keeping upstream's env prefix and URL-arg handling
    sed -i 's|^Exec=.*|Exec=env RUST_LOG=info,nym_vpn_app=debug /usr/bin/NymVPN.AppImage -l %U|' app.desktop
    install -Dm644 app.desktop /usr/share/applications/nym-vpn.desktop
    echo "Desktop entry installed"
  else
    echo "Warning: could not fetch $DESKTOP_URL" >&2
  fi

  if curl -fsSL "$ICON_URL" -o icon.svg; then
    install -Dm644 icon.svg /usr/share/icons/hicolor/scalable/apps/nym-vpn.svg
    echo "Icon installed"
  else
    echo "Warning: could not fetch $ICON_URL" >&2
  fi
else
  echo "Warning: no app asset, skipping app install" >&2
fi

echo "Installation complete."
