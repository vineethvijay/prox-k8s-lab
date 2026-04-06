#!/usr/bin/env bash
set -euo pipefail

# Storage benchmark: Longhorn PVC vs NFS (hostPath) write/read speed
# Single pod, dd-based, auto-cleanup

NS="storage-bench"
BOLD='\033[1m' CYAN='\033[0;36m' NC='\033[0m'

cleanup() {
  echo -e "\n${CYAN}Cleaning up...${NC}"
  kubectl delete ns "$NS" --ignore-not-found --wait=false
  kubectl delete sc longhorn-bench --ignore-not-found 2>/dev/null
  if [[ -n "${ORIG_OVERPROV:-}" ]]; then
    kubectl patch settings.longhorn.io storage-over-provisioning-percentage \
      -n longhorn-system --type merge -p "{\"value\":\"${ORIG_OVERPROV}\"}" 2>/dev/null
  fi
}
trap cleanup EXIT

echo -e "${BOLD}=== Storage Bench: Longhorn vs NFS ===${NC}\n"

# Bump over-provisioning temporarily (cluster disks are near full)
ORIG_OVERPROV=$(kubectl get settings.longhorn.io storage-over-provisioning-percentage \
  -n longhorn-system -o jsonpath='{.value}')
kubectl patch settings.longhorn.io storage-over-provisioning-percentage \
  -n longhorn-system --type merge -p '{"value":"200"}'
echo -e "${CYAN}Longhorn over-provisioning: ${ORIG_OVERPROV}% -> 200% (temp)${NC}"

# Create namespace + StorageClass (1 replica) + PVC
kubectl create ns "$NS"
cat <<'EOF' | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn-bench
provisioner: driver.longhorn.io
reclaimPolicy: Delete
parameters:
  numberOfReplicas: "1"
  dataEngine: "v1"
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: bench-longhorn
  namespace: storage-bench
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: longhorn-bench
  resources:
    requests:
      storage: 512Mi
EOF

echo -e "${CYAN}Waiting for PVC to bind...${NC}"
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/bench-longhorn -n "$NS" --timeout=120s

# Single pod: Longhorn PVC + NFS hostPath (already mounted on workers)
echo -e "${CYAN}Launching benchmark pod...${NC}"
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: storage-bench
  namespace: storage-bench
spec:
  restartPolicy: Never
  containers:
  - name: bench
    image: debian:bookworm-slim
    command: ["/bin/bash", "-c"]
    args:
    - |
      run_dd() {
        local label=$1 dir=$2
        echo "===== $label ====="
        echo "-- Write 256M (1M x 256) --"
        dd if=/dev/zero of=$dir/bench bs=1M count=256 oflag=dsync 2>&1 | tail -1
        echo "-- Read 256M --"
        dd if=$dir/bench of=/dev/null bs=1M 2>&1 | tail -1
        echo "-- Write 4K x 1024 --"
        dd if=/dev/zero of=$dir/bench4k bs=4k count=1024 oflag=dsync 2>&1 | tail -1
        echo "-- Read 4K x 1024 --"
        dd if=$dir/bench4k of=/dev/null bs=4k 2>&1 | tail -1
        rm -f $dir/bench $dir/bench4k
        echo ""
      }
      run_dd "LONGHORN" /longhorn
      run_dd "NFS (HDD-INT)" /hdd-int
      run_dd "NFS (NAS)" /nfs
    volumeMounts:
    - { name: longhorn, mountPath: /longhorn }
    - { name: hdd-int,  mountPath: /hdd-int }
    - { name: nfs,      mountPath: /nfs }
  volumes:
  - name: longhorn
    persistentVolumeClaim:
      claimName: bench-longhorn
  - name: hdd-int
    hostPath:
      path: /mnt/nfs/hdd-int
      type: Directory
  - name: nfs
    hostPath:
      path: /mnt/nfs/nas-media
      type: Directory
EOF

echo -e "${CYAN}Waiting for pod to finish (may take a few minutes)...${NC}"
kubectl wait --for=condition=Ready pod/storage-bench -n "$NS" --timeout=180s 2>/dev/null || true
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/storage-bench -n "$NS" --timeout=600s

echo ""
kubectl logs storage-bench -n "$NS"
echo -e "\n${BOLD}=== Done ===${NC}"
