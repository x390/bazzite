#!/bin/bash
set -euo pipefail

# Toggle extra diagnostic output with DEBUG=1
DEBUG=${DEBUG:-0}
log() { echo "[nym-install] $*"; }
dbg() { [ "$DEBUG" = "1" ] && echo "[nym-install:debug] $*" >&2; return 0; }

AUTH_ARGS=()
[ -n "${GITHUB_TOKEN:-}" ] && { AUTH_ARGS=(-H "Authorization: Bearer ${GITHUB_TOKEN}"); dbg "using GITHUB_TOKEN"; }

log "Fetching release list..."
RELEASES_JSON=$(curl -fsSL "${AUTH_ARGS[@]}" \
  "https://api.github.com/repos/nymtech/nym-vpn-client/releases?per_page=100")

REL_COUNT=$(echo "$RELEASES_JSON" | jq 'length')
STABLE_COUNT=$(echo "$RELEASES_JSON" | jq '[.[] | select(.draft==false and .prerelease==false)] | length')
log "Got ${REL_COUNT} releases (${STABLE_COUNT} stable)"
if [ "$DEBUG" = "1" ]; then
  echo "[nym-install:debug] recent release tags (top 10):" >&2
  echo "$RELEASES_JSON" | jq -r '.[0:10][] | "  \(.tag_name)  draft=\(.draft) prerelease=\(.prerelease)  assets=\(.assets|length)"' >&2
fi

# --- Core: latest stable release containing a linux_x86_64 core tarball ---
# NOTE: single-backslash escapes here. --arg values are NOT jq-string-escaped;
# doubling them turns \. into a literal backslash + wildcard and matches nothing.
CORE_RE='nym-vpn-core-v.*_linux_x86_64\.tar\.gz$'
CORE_REL_JSON=$(echo "$RELEASES_JSON" | jq --arg re "$CORE_RE" \
  '[.[] | select(.draft==false and .prerelease==false)]
   | map(select(.assets[].name | test($re))) | .[0]')

if [ "$CORE_REL_JSON" == "null" ]; then
  echo "No release with Linux core tarball (pattern: $CORE_RE)" >&2
  echo "Recent stable release tags + their linux asset names for triage:" >&2
  echo "$RELEASES_JSON" | jq -r '
    [.[] | select(.draft==false and .prerelease==false)][0:5][]
    | "  tag: \(.tag_name)\n    linux assets: \([.assets[].name | select(test("linux|AppImage"))] | join(", "))"
  ' >&2
  exit 1
fi

CORE_TAG=$(echo "$CORE_REL_JSON" | jq -r '.tag_name')
CORE_URL=$(echo "$CORE_REL_JSON" | jq -r --arg re "$CORE_RE" \
  '.assets[] | select(.name | test($re)) | .browser_download_url' | head -n1)
CORE_ARCHIVE=$(basename "$CORE_URL")
NYM_VERSION=$(echo "$CORE_ARCHIVE" | sed -E 's/nym-vpn-core-v(.*)_linux_x86_64\.tar\.gz/\1/')
log "Core: v${NYM_VERSION} (tag: ${CORE_TAG})"
dbg "CORE_URL=$CORE_URL"

# --- App: latest stable release containing an x86_64 AppImage (independent query) ---
APP_RE='(x64|amd64|x86_64)[^/]*\.AppImage$'
APP_REL_JSON=$(echo "$RELEASES_JSON" | jq --arg re "$APP_RE" \
  '[.[] | select(.draft==false and .prerelease==false)]
   | map(select(.assets[].name | test($re))) | .[0]')

APP_URL="" APP_TAG=""
if [ "$APP_REL_JSON" != "null" ]; then
  APP_URL=$(echo "$APP_REL_JSON" | jq -r --arg re "$APP_RE" \
    '.assets[] | select(.name | test($re)) | .browser_download_url' | head -n1)
  APP_TAG=$(echo "$APP_REL_JSON" | jq -r '.tag_name')
  log "App: $(basename "$APP_URL") (tag: ${APP_TAG})"
  dbg "APP_URL=$APP_URL"
else
  echo "Warning: no x86_64 AppImage found in any stable release (pattern: $APP_RE)" >&2
fi

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT
cd "$TEMP_DIR"

# Fetch + sha256 verify (upstream pattern)
fetch_verified() {
  local url=$1 out=$2
  dbg "fetch $url -> $out"
  curl -fsSL "$url" -o "$out"
  curl -fsSL "$url.sha256sum" -o "$out.sha256sum"
  sha256sum --check --status "$out.sha256sum" || {
    echo "sha256 verification failed for $out" >&2
    sha256sum "$out" >&2
    cat "$out.sha256sum" >&2
    exit 1
  }
  dbg "verified $out"
}

# --- Daemon ---
log "Downloading core archive..."
fetch_verified "$CORE_URL" "$CORE_ARCHIVE"
tar -xzf "$CORE_ARCHIVE"
CORE_DIR="${CORE_ARCHIVE%.tar.gz}"
dbg "extracted to $CORE_DIR: $(ls "$CORE_DIR")"

install -Dm755 "$CORE_DIR/nym-vpnd"         /usr/bin/nym-vpnd
install -Dm755 "$CORE_DIR/nym-socks5-proxy" /usr/bin/nym-socks5-proxy
log "Installed /usr/bin/nym-vpnd and /usr/bin/nym-socks5-proxy"

# Unit file: canonical path per upstream installer
UNIT_URL="https://raw.githubusercontent.com/nymtech/nym-vpn-client/refs/tags/${CORE_TAG}/nym-vpn-core/crates/nym-vpnd/.pkg/aur/nym-vpnd.service"
log "Fetching unit file..."
dbg "UNIT_URL=$UNIT_URL"
curl -fsSL "$UNIT_URL" -o nym-vpnd.service
grep -q '^ExecStart=.*nym-vpnd' nym-vpnd.service || {
  echo "Downloaded unit doesn't look valid. First 20 lines:" >&2
  head -20 nym-vpnd.service >&2
  exit 1
}
install -Dm644 nym-vpnd.service /usr/lib/systemd/system/nym-vpnd.service

mkdir -p /etc/nym/
log "Enabling nym-vpnd.service (offline)..."
systemctl enable --root=/ nym-vpnd.service

# --- App ---
if [ -n "$APP_URL" ]; then
  APP_FILE=$(basename "$APP_URL")
  log "Downloading AppImage..."
  fetch_verified "$APP_URL" "$APP_FILE"

  install -Dm755 "$APP_FILE" /usr/bin/NymVPN.AppImage
  ln -sf /usr/bin/NymVPN.AppImage /usr/bin/nym-vpn-app
  log "Installed /usr/bin/NymVPN.AppImage (symlink: nym-vpn-app)"

  DESKTOP_URL="https://raw.githubusercontent.com/nymtech/nym-vpn-client/refs/tags/${APP_TAG}/nym-vpn-app/.pkg/app.desktop"
  ICON_URL="https://raw.githubusercontent.com/nymtech/nym-vpn-client/refs/tags/${APP_TAG}/nym-vpn-app/.pkg/icon.svg"
  dbg "DESKTOP_URL=$DESKTOP_URL"
  dbg "ICON_URL=$ICON_URL"

  if curl -fsSL "$DESKTOP_URL" -o app.desktop; then
    sed -i 's|^Exec=.*|Exec=env RUST_LOG=info,nym_vpn_app=debug /usr/bin/NymVPN.AppImage -l %U|' app.desktop
    install -Dm644 app.desktop /usr/share/applications/nym-vpn.desktop
    log "Installed /usr/share/applications/nym-vpn.desktop"
  else
    echo "Warning: could not fetch $DESKTOP_URL" >&2
  fi

  if curl -fsSL "$ICON_URL" -o icon.svg; then
    install -Dm644 icon.svg /usr/share/icons/hicolor/scalable/apps/nym-vpn.svg
    log "Installed /usr/share/icons/hicolor/scalable/apps/nym-vpn.svg"
  else
    echo "Warning: could not fetch $ICON_URL" >&2
  fi
else
  echo "Warning: no app asset, skipping app install" >&2
fi

log "Installation complete."
