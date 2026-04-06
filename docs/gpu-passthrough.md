# GPU Passthrough - Proxmox K8s Cluster

## Hardware Inventory

### Proxmox 1 — `192.168.1.8` (HP, AMD Ryzen)

| GPU | Type | PCI Address | IOMMU Group | PCI ID | Driver |
|-----|------|-------------|-------------|--------|--------|
| AMD Lucienne (Renoir iGPU) | Integrated | `03:00.0` | 10 | `1002:164c` | `amdgpu` |
| AMD Renoir HD Audio | Audio | `03:00.1` | 11 | `1002:1637` | — |

- **IOMMU**: Not enabled in GRUB (`quiet` only). Needs `amd_iommu=on iommu=pt`
- **Devices**: `/dev/dri/card1`, `/dev/dri/renderD128`
- **VMs on this host**: k8s-w4 (204), k8s-cp2 (205)
- **Transcoding support**: VAAPI (AMD VCN — H.264/H.265 encode/decode)

### Proxmox 2 — `192.168.1.11` (Lenovo, Intel i7 + NVIDIA)

| GPU | Type | PCI Address | IOMMU Group | PCI ID | Driver |
|-----|------|-------------|-------------|--------|--------|
| Intel UHD 630 (CoffeeLake) | Integrated | `00:02.0` | 0 | `8086:3e9b` | `i915` |
| NVIDIA GTX 1650 Mobile/Max-Q | Discrete | `01:00.0` | 2 | `10de:1f91` | `nvidia` |
| NVIDIA TU117 HD Audio | Audio | `01:00.1` | 2 | `10de:10fa` | — |

- **IOMMU**: ✅ Enabled (`intel_iommu=on iommu=pt` in GRUB)
- **Devices**: `/dev/dri/card1` (Intel), `/dev/dri/card2` (NVIDIA), `/dev/dri/renderD128`, `/dev/dri/renderD129`
- **VMs on this host**: k8s-cp (200), k8s-w1 (201), k8s-w2 (202), k8s-cp3 (206)

---

## Current Setup: Intel iGPU → k8s-w2

The Intel UHD 630 iGPU is passed through to VM 202 (k8s-w2) for Jellyfin hardware transcoding.

### What was done

1. **IOMMU** was already enabled on proxmox2 (`intel_iommu=on iommu=pt`)
2. **PCI passthrough** added to VM 202:
   ```
   hostpci0: 0000:00:02.0,rombar=0
   ```
3. **i915 kernel module** installed and set to autoload in the VM:
   ```bash
   apt install linux-modules-extra-$(uname -r)
   echo i915 > /etc/modules-load.d/i915.conf
   ```
4. **Jellyfin pod** configured with:
   - `nodeSelector: kubernetes.io/hostname: k8s-w2`
   - `/dev/dri` mounted as hostPath volume
   - `securityContext.privileged: true`

### Enabling in Jellyfin UI

1. Go to **Dashboard → Playback → Transcoding**
2. Set **Hardware acceleration** to `Video Acceleration API (VAAPI)`
3. Set **VA-API Device** to `/dev/dri/renderD128`
4. Enable desired codecs (H.264, HEVC, etc.)
5. Save

---

## Future: NVIDIA GTX 1650 Passthrough

The GTX 1650 (NVENC/NVDEC) is significantly more powerful for transcoding than the Intel iGPU. Here's what's needed to enable it.

### Prerequisites

1. **Blacklist nvidia on Proxmox host** (so the host releases the GPU):
   ```bash
   # /etc/modprobe.d/blacklist-nvidia.conf
   blacklist nvidia
   blacklist nvidia_drm
   blacklist nvidia_modeset
   blacklist nouveau
   ```

2. **Load vfio-pci for the NVIDIA GPU** before any other driver:
   ```bash
   # /etc/modprobe.d/vfio.conf
   options vfio-pci ids=10de:1f91,10de:10fa
   ```

3. **Add vfio modules to initramfs**:
   ```bash
   # /etc/modules
   vfio
   vfio_iommu_type1
   vfio_pci
   ```

4. **Update initramfs and reboot Proxmox host**:
   ```bash
   update-initramfs -u -k all
   reboot
   ```

### VM Configuration

Add both GPU and audio device (same IOMMU group 2):
```bash
qm set <VMID> -hostpci0 0000:01:00,pcie=1,rombar=0
```
> Note: Using `01:00` (without function) passes through both `01:00.0` (GPU) and `01:00.1` (Audio)

The VM also needs:
```bash
qm set <VMID> -machine q35
qm set <VMID> -bios ovmf   # UEFI boot required for GPU passthrough
```

### Inside the VM

1. **Install NVIDIA drivers**:
   ```bash
   apt install -y nvidia-driver-560  # or latest available
   nvidia-smi  # verify
   ```

2. **Install nvidia-container-toolkit** (for K8s):
   ```bash
   curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
     sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
   curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
     sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
     sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
   sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit
   sudo nvidia-ctk runtime configure --runtime=containerd
   sudo systemctl restart containerd
   ```

3. **Deploy NVIDIA device plugin in K8s**:
   ```bash
   kubectl create -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.17.0/deployments/static/nvidia-device-plugin.yml
   ```

4. **Update Jellyfin deployment** to request NVIDIA GPU:
   ```yaml
   resources:
     limits:
       nvidia.com/gpu: 1
   ```
   And in Jellyfin UI, set hardware acceleration to **NVIDIA NVENC**.

### Important Notes

- The Proxmox host will **lose access** to the NVIDIA GPU once vfio-pci claims it
- The VM must use **q35 machine type** and **UEFI (OVMF) BIOS** for PCIe passthrough
- NVIDIA audio device (`01:00.1`) must be passed through together (same IOMMU group)
- Only **one VM** can use the GPU at a time (no sharing without vGPU/MIG, which GTX doesn't support)
- If the VM is on a different host than the GPU, this won't work — GPU passthrough is physical host-bound

---

## Quick Reference

| Feature | Intel iGPU (current) | NVIDIA GTX 1650 (future) |
|---------|---------------------|--------------------------|
| Host | proxmox2 (192.168.1.11) | proxmox2 (192.168.1.11) |
| API | VAAPI / QSV | NVENC / NVDEC |
| Passthrough type | PCI passthrough | PCIe passthrough |
| VM requirements | Standard BIOS, any machine | OVMF BIOS, q35 machine |
| K8s integration | hostPath `/dev/dri` + privileged | nvidia-device-plugin + resource limits |
| Sharing | GVT-g (not supported on this CPU) | Not supported (no vGPU on GTX) |
| Transcoding quality | Good | Excellent |
| Power draw | ~15W | ~50W |
