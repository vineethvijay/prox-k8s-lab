#!/usr/bin/env bash
set -euo pipefail

# Migrate Longhorn PVC data → nfs-hdd PVC (PVC-to-PVC via tar).
# Uses busybox (no package installs), tar pipe for fast copy, parallel support.
#
# Usage:
#   ./scripts/migrate-longhorn-to-nfs.sh                    # migrate all (sequential)
#   ./scripts/migrate-longhorn-to-nfs.sh -p                 # migrate all (parallel)
#   ./scripts/migrate-longhorn-to-nfs.sh jellyfin plex      # migrate specific apps
#   ./scripts/migrate-longhorn-to-nfs.sh -p jellyfin plex   # specific apps in parallel

BOLD='\033[1m' CYAN='\033[0;36m' GREEN='\033[0;32m' RED='\033[0;31m' YELLOW='\033[0;33m' NC='\033[0m'
NS="default"
DEST_SC="nfs-hdd"
MIGRATOR_IMAGE="busybox:1.36"
PARALLEL=false

# Format: "deployment_name:pvc_name:capacity"
ALL_APPS=(
  "bazarr:bazarr-config:1Gi"
  "filebrowser:filebrowser-config:256Mi"
  "gatus:gatus-data:1Gi"
  "homarr:homarr-config:1Gi"
  "jellyfin:jellyfin-config:10Gi"
  "jellystat-db:jellystat-db:2Gi"
  "jellystat:jellystat-backup:1Gi"
  "lidarr:lidarr-config:256Mi"
  "plex:plex-config:5Gi"
  "prowlarr:prowlarr-config:1Gi"
  "vpn-downloader:downloader-config:256Mi"
  "radarr:radarr-config:5Gi"
  "readarr:readarr-config:1Gi"
  "sabnzbd:sabnzbd-config:1Gi"
  "seerr:seerr-config:2Gi"
  "sonarr:sonarr-config:1Gi"
  "tautulli:tautulli-config:1Gi"
)

# Parse flags
ARGS=()
for arg in "$@"; do
  if [[ "$arg" == "-p" || "$arg" == "--parallel" ]]; then
    PARALLEL=true
  else
    ARGS+=("$arg")
  fi
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

# Filter to requested apps if args provided
if [[ $# -gt 0 ]]; then
  FILTERED=()
  for arg in "$@"; do
    for entry in "${ALL_APPS[@]}"; do
      if [[ "$entry" == "$arg:"* ]]; then
        FILTERED+=("$entry")
      fi
    done
  done
  if [[ ${#FILTERED[@]} -eq 0 ]]; then
    echo -e "${RED}No matching apps found for: $*${NC}"
    exit 1
  fi
  ALL_APPS=("${FILTERED[@]}")
fi

echo -e "${BOLD}=== Longhorn → NFS-HDD PVC Migration ===${NC}"
echo -e "Destination SC: ${DEST_SC}  |  Image: ${MIGRATOR_IMAGE}  |  Parallel: ${PARALLEL}"
echo -e "Apps to migrate: ${#ALL_APPS[@]}\n"

create_dest_pvc() {
  local pvc="$1" capacity="$2"
  local dest_pvc="${pvc}-nfs"

  if kubectl get pvc "$dest_pvc" -n "$NS" &>/dev/null; then
    echo -e "${YELLOW}  PVC ${dest_pvc} already exists, reusing.${NC}"
    return
  fi

  echo -e "${CYAN}  Creating destination PVC: ${dest_pvc} (${capacity}, ${DEST_SC})${NC}"
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${dest_pvc}
  namespace: ${NS}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: ${DEST_SC}
  resources:
    requests:
      storage: ${capacity}
EOF
}

scale_down_deploy() {
  local deploy="$1"
  local orig_replicas
  orig_replicas=$(kubectl get deploy "$deploy" -n "$NS" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
  if [[ "$orig_replicas" != "0" ]]; then
    echo -e "${CYAN}  Scaling down ${deploy} (was ${orig_replicas})...${NC}"
    kubectl scale deploy "$deploy" -n "$NS" --replicas=0
    kubectl wait --for=delete pod -l app="$deploy" -n "$NS" --timeout=120s 2>/dev/null || true
  fi
}

migrate_one() {
  local deploy="$1" pvc="$2" capacity="$3"
  local dest_pvc="${pvc}-nfs"
  local pod_name="migrate-${pvc}"

  echo -e "\n${BOLD}--- Migrating: ${pvc} → ${dest_pvc} ---${NC}"

  # Check source PVC exists
  if ! kubectl get pvc "$pvc" -n "$NS" &>/dev/null; then
    echo -e "${YELLOW}  Source PVC $pvc not found, skipping.${NC}"
    return
  fi

  # Create destination PVC
  create_dest_pvc "$pvc" "$capacity"

  # Scale down deployment
  scale_down_deploy "$deploy"

  # For jellystat, also scale down the other deployment
  if [[ "$deploy" == "jellystat-db" ]]; then
    scale_down_deploy "jellystat"
  fi
  if [[ "$deploy" == "jellystat" ]]; then
    scale_down_deploy "jellystat-db"
  fi

  # Clean up any leftover migration pod
  kubectl delete pod "$pod_name" -n "$NS" --ignore-not-found --wait=true 2>/dev/null

  # Launch migration pod — uses tar pipe (no package installs needed)
  echo -e "${CYAN}  Launching migration pod (src: ${pvc}, dst: ${dest_pvc})...${NC}"
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
  namespace: ${NS}
spec:
  restartPolicy: Never
  containers:
  - name: migrate
    image: ${MIGRATOR_IMAGE}
    command: ["/bin/sh", "-c"]
    args:
    - |
      set -e
      echo "Cleaning destination..."
      rm -rf /dst/* /dst/.[!.]* /dst/..?* 2>/dev/null || true
      echo "Copying via tar pipe..."
      SRC_COUNT=\$(find /src -type f | wc -l)
      tar cf - -C /src . | tar xf - -C /dst
      DST_COUNT=\$(find /dst -type f | wc -l)
      SRC_SIZE=\$(du -sh /src | cut -f1)
      DST_SIZE=\$(du -sh /dst | cut -f1)
      echo "Source: \$SRC_COUNT files (\$SRC_SIZE)  Dest: \$DST_COUNT files (\$DST_SIZE)"
      if [ "\$SRC_COUNT" != "\$DST_COUNT" ]; then
        echo "ERROR: File count mismatch!"
        exit 1
      fi
      echo "OK"
    volumeMounts:
    - name: src
      mountPath: /src
      readOnly: true
    - name: dst
      mountPath: /dst
  volumes:
  - name: src
    persistentVolumeClaim:
      claimName: ${pvc}
  - name: dst
    persistentVolumeClaim:
      claimName: ${dest_pvc}
EOF

  # Wait for pod to complete
  echo -e "${CYAN}  Waiting for copy to complete...${NC}"
  kubectl wait --for=condition=Ready pod/"$pod_name" -n "$NS" --timeout=300s 2>/dev/null || true
  kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/"$pod_name" -n "$NS" --timeout=600s

  # Show logs
  kubectl logs "$pod_name" -n "$NS" | tail -3

  # Check exit code
  local exit_code
  exit_code=$(kubectl get pod "$pod_name" -n "$NS" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}')
  if [[ "$exit_code" != "0" ]]; then
    echo -e "${RED}  FAILED! Check: kubectl logs ${pod_name} -n ${NS}${NC}"
    return 1
  fi

  # Cleanup migration pod
  kubectl delete pod "$pod_name" -n "$NS" --ignore-not-found

  echo -e "${GREEN}  ✓ ${pvc} → ${dest_pvc} migrated successfully.${NC}"
}

# Run migrations
FAILED=()
PIDS=()
if [[ "$PARALLEL" == true ]]; then
  echo -e "${CYAN}Running migrations in parallel...${NC}"
  for entry in "${ALL_APPS[@]}"; do
    IFS=: read -r deploy pvc capacity <<< "$entry"
    (migrate_one "$deploy" "$pvc" "$capacity") &
    PIDS+=($!)
  done
  for i in "${!PIDS[@]}"; do
    if ! wait "${PIDS[$i]}"; then
      IFS=: read -r _ pvc _ <<< "${ALL_APPS[$i]}"
      FAILED+=("$pvc")
    fi
  done
else
  for entry in "${ALL_APPS[@]}"; do
    IFS=: read -r deploy pvc capacity <<< "$entry"
    if ! migrate_one "$deploy" "$pvc" "$capacity"; then
      FAILED+=("$pvc")
    fi
  done
fi

echo -e "\n${BOLD}=== Migration Summary ===${NC}"
echo -e "Total: ${#ALL_APPS[@]}"
if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo -e "${RED}Failed: ${FAILED[*]}${NC}"
  echo -e "Failed apps left scaled to 0. Fix and re-run for those apps."
  exit 1
else
  echo -e "${GREEN}All ${#ALL_APPS[@]} PVCs migrated successfully!${NC}"
  echo -e "\n${BOLD}Next steps:${NC}"
  echo -e "  1. Update each chart's values.yaml with existingClaim pointing to the -nfs PVC"
  echo -e "  2. Push to git → ArgoCD syncs → apps start using nfs-hdd PVCs"
  echo -e "  3. Once confirmed working, delete old Longhorn PVCs"
fi
