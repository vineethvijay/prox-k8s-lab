#!/usr/bin/env bash
# helm-adopt-resources.sh
# Annotates and labels existing K8s resources so Helm can adopt them
# without "already exists" errors on first `helm install`.
#
# Usage:
#   bash scripts/helm-adopt-resources.sh          # dry-run (default)
#   bash scripts/helm-adopt-resources.sh --apply   # actually annotate
set -euo pipefail

DRY_RUN=true
[[ "${1:-}" == "--apply" ]] && DRY_RUN=false

# ── Helper ──────────────────────────────────────────────────────────
annotate() {
  local kind="$1" name="$2" namespace="$3" release="$4"

  local ns_flag="-n $namespace"

  if $DRY_RUN; then
    echo "[dry-run] $kind/$name in $namespace → release=$release"
    return
  fi

  # Check resource exists
  if ! kubectl get "$kind" "$name" $ns_flag &>/dev/null; then
    echo "[skip] $kind/$name not found in $namespace"
    return
  fi

  kubectl annotate "$kind" "$name" $ns_flag \
    meta.helm.sh/release-name="$release" \
    meta.helm.sh/release-namespace="$namespace" \
    --overwrite

  kubectl label "$kind" "$name" $ns_flag \
    app.kubernetes.io/managed-by=Helm \
    --overwrite

  echo "[done] $kind/$name in $namespace → release=$release"
}

# ── Media apps (namespace: default) ────────────────────────────────
# Simple apps: PVC + Deployment + Service + Ingress
for app in sonarr radarr bazarr lidarr readarr prowlarr seerr tautulli; do
  annotate persistentvolumeclaim "${app}-config" default "$app"
  annotate deployment "$app" default "$app"
  annotate service "$app" default "$app"
  annotate ingress "${app}-ingress" default "$app"
done

# sabnzbd
annotate persistentvolumeclaim "sabnzbd-config" default "sabnzbd"
annotate deployment "sabnzbd" default "sabnzbd"
annotate service "sabnzbd" default "sabnzbd"
annotate ingress "sabnzbd-ingress" default "sabnzbd"

# flaresolverr (no PVC, no ingress)
annotate deployment "flaresolverr" default "flaresolverr"
annotate service "flaresolverr" default "flaresolverr"

# jellyfin
annotate persistentvolumeclaim "jellyfin-config" default "jellyfin"
annotate deployment "jellyfin" default "jellyfin"
annotate service "jellyfin" default "jellyfin"
annotate ingress "jellyfin-ingress" default "jellyfin"

# plex
annotate persistentvolumeclaim "plex-config" default "plex"
annotate deployment "plex" default "plex"
annotate service "plex" default "plex"
annotate ingress "plex-ingress" default "plex"

# jellystat
annotate secret "jellystat-secrets" default "jellystat"
annotate persistentvolumeclaim "jellystat-db" default "jellystat"
annotate persistentvolumeclaim "jellystat-backup" default "jellystat"
annotate deployment "jellystat-db" default "jellystat"
annotate deployment "jellystat" default "jellystat"
annotate service "jellystat-db" default "jellystat"
annotate service "jellystat" default "jellystat"
annotate ingress "jellystat-ingress" default "jellystat"

# vpn-downloader
annotate secret "vpn-credentials" default "vpn-downloader"
annotate persistentvolumeclaim "downloader-config" default "vpn-downloader"
annotate deployment "vpn-downloader" default "vpn-downloader"
annotate service "downloader" default "vpn-downloader"
annotate ingress "downloader-ingress" default "vpn-downloader"

# filebrowser
annotate persistentvolumeclaim "filebrowser-config" default "filebrowser"
annotate configmap "filebrowser-config-file" default "filebrowser"
annotate deployment "filebrowser" default "filebrowser"
annotate service "filebrowser" default "filebrowser"
annotate ingress "filebrowser-ingress" default "filebrowser"

# ── Infrastructure ─────────────────────────────────────────────────
# glances (DaemonSet in homepage namespace)
annotate daemonset "glances" homepage "glances"

# headlamp
annotate serviceaccount "headlamp-admin" headlamp "headlamp"
annotate clusterrolebinding "headlamp-admin" headlamp "headlamp"
annotate secret "headlamp-admin-token" headlamp "headlamp"
annotate ingress "headlamp-ingress" headlamp "headlamp"

# longhorn-ingress
annotate ingress "longhorn-ingress" longhorn-system "longhorn-ingress"

# metallb-config
annotate ipaddresspool "homelab-pool" metallb-system "metallb-config"
annotate l2advertisement "homelab-advertisement" metallb-system "metallb-config"

# ── Summary ────────────────────────────────────────────────────────
echo ""
if $DRY_RUN; then
  echo "=== DRY RUN complete. Run with --apply to annotate for real ==="
else
  echo "=== All resources annotated for Helm adoption ==="
fi
