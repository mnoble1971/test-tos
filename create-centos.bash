#!/usr/bin/env bash
# Download image (run once):
# cd /var/lib/libvirt/images/
# curl -fL -O https://cloud.centos.org/centos/10-stream/x86_64/images/CentOS-Stream-GenericCloud-10-latest.x86_64.qcow2

set -euo pipefail

# ---------------------------------------------------
# INPUT VALIDATION
# ---------------------------------------------------
if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <vm-name>"
  echo "Example: $0 cs10-vm1"
  exit 1
fi

VMNAME="$1"

# ---------------------------------------------------
# VM SETTINGS
# ---------------------------------------------------
VCPUS="2"
RAM_MB="4096"
DISK_GB="40"
LIBVIRT_NET="default"   # use "default" unless you know you have a bridge
USERNAME="centos"
HOSTNAME="$VMNAME"

BASE="/var/lib/libvirt/images/CentOS-Stream-GenericCloud-10-latest.x86_64.qcow2"
IMAGEDIR="/var/lib/libvirt/images"
DISK="${IMAGEDIR}/${VMNAME}.qcow2"
SEEDDIR="${IMAGEDIR}/cloudinit-${VMNAME}"
SEEDISO="${IMAGEDIR}/seed-${VMNAME}.iso"

# ---------------------------------------------------
# PRE-FLIGHT CHECKS
# ---------------------------------------------------
sudo mkdir -p "$IMAGEDIR"
sudo test -f "$BASE" || {
  echo "ERROR: Base image not found: $BASE"
  exit 1
}

if sudo virsh dominfo "$VMNAME" &>/dev/null; then
  echo "ERROR: VM '$VMNAME' already exists"
  exit 1
fi

# ---------------------------------------------------
echo "[1/4] Creating overlay disk for VM: $VMNAME"
# ---------------------------------------------------
sudo qemu-img create -f qcow2 -F qcow2 \
  -b "$BASE" \
  "$DISK" "${DISK_GB}G"

# ---------------------------------------------------
echo "[2/4] Creating cloud-init seed ISO"
# ---------------------------------------------------
sudo mkdir -p "$SEEDDIR"

echo "Enter password for VM user '$USERNAME':"
PASSHASH="$(openssl passwd -6)"

sudo tee "${SEEDDIR}/user-data" >/dev/null <<EOF
#cloud-config
hostname: ${HOSTNAME}
users:
  - name: ${USERNAME}
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: wheel
    shell: /bin/bash
    lock_passwd: false
    passwd: ${PASSHASH}
ssh_pwauth: true
disable_root: false
chpasswd:
  expire: false
EOF

sudo tee "${SEEDDIR}/meta-data" >/dev/null <<EOF
instance-id: ${VMNAME}
local-hostname: ${HOSTNAME}
EOF

if command -v cloud-localds >/dev/null 2>&1; then
  sudo cloud-localds -v "$SEEDISO" \
    "${SEEDDIR}/user-data" \
    "${SEEDDIR}/meta-data"
else
  sudo genisoimage -output "$SEEDISO" -volid cidata -joliet -rock \
    "${SEEDDIR}/user-data" \
    "${SEEDDIR}/meta-data"
fi

# ---------------------------------------------------
echo "[3/4] Creating VM with virt-install"
# ---------------------------------------------------
sudo virt-install \
  --name "$VMNAME" \
  --memory "$RAM_MB" \
  --vcpus "$VCPUS" \
  --import \
  --disk "path=$DISK,format=qcow2,bus=virtio" \
  --disk "path=$SEEDISO,device=cdrom" \
  --network "network=${LIBVIRT_NET},model=virtio" \
  --osinfo detect=on,require=off \
  --graphics none \
  --console pty,target_type=serial \
  --noautoconsole

# ---------------------------------------------------
echo "[4/4] Done"
# ---------------------------------------------------
echo "VM created: $VMNAME"
echo
echo "Connect to console:"
echo "  sudo virsh console $VMNAME"
echo "Exit console with: Ctrl+]"
echo
echo "Login:"
echo "  user: $USERNAME"
echo "  pass: (password you entered)"
