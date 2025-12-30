#!/bin/bash
# =======================================================================================
# PROJECT: Arch OEM Installer
# DESCRIPTION: Installs Arch with a Read-Only SquashFS Recovery Partition & Separate Home Disk
# AUTHOR: [Your Name]
# LICENSE: MIT
# =======================================================================================

set -e

# --- CONFIGURATION ---
ISO_MOUNT="/run/archiso/cowspace"  # Where the live system is running from
RECOVERY_WORK_DIR="/tmp/arch_recovery_build"
MOUNT_POINT="/mnt"

# Check for UEFI
if [ ! -d "/sys/firmware/efi/efivars" ]; then
    echo "❌ Error: System is not booted in UEFI mode. Aborting."
    exit 1
fi

echo "=================================================================="
echo "      ARCH LINUX OEM-STYLE INSTALLER"
echo "=================================================================="
echo "This script will wipe two drives to create:"
echo "1. MAIN DISK: Boot, Recovery (SquashFS), Var, Root"
echo "2. HOME DISK: Home Partition"
echo "=================================================================="

# --- 1. DISK SELECTION ---
lsblk -d -p -n -o NAME,SIZE,MODEL | grep -v "loop"
echo ""
read -p "Select MAIN DISK (e.g. /dev/nvme0n1): " DISK_MAIN
read -p "Select HOME DISK (e.g. /dev/sda): " DISK_HOME
read -p "Enter Size for Root Partition (e.g. 50G): " ROOT_SIZE

if [ -z "$DISK_MAIN" ] || [ -z "$DISK_HOME" ]; then
    echo "❌ Error: Disks cannot be empty."
    exit 1
fi

if [ "$DISK_MAIN" == "$DISK_HOME" ]; then
    echo "❌ Error: Main disk and Home disk must be different for this layout."
    exit 1
fi

# Confirm
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo "WARNING: ALL DATA ON $DISK_MAIN AND $DISK_HOME WILL BE DESTROYED."
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
read -p "Type 'DESTROY' to continue: " CONFIRM
if [ "$CONFIRM" != "DESTROY" ]; then
    echo "Aborted."
    exit 1
fi

# --- 2. INSTALL DEPENDENCIES ---
echo ">> Installing necessary tools (squashfs-tools)..."
pacman -Sy --noconfirm squashfs-tools gptfdisk dosfstools arch-install-scripts > /dev/null

# --- 3. PARTITIONING ---
echo ">> Partitioning Main Disk: $DISK_MAIN..."
sgdisk -Z $DISK_MAIN > /dev/null
# 1: Boot (EFI) - 1GB
sgdisk -n 1:0:+1G -t 1:ef00 -c 1:"EFI_System" $DISK_MAIN > /dev/null
# 2: Recovery (RO) - 10GB
sgdisk -n 2:0:+10G -t 2:8300 -c 2:"Recovery_Image" $DISK_MAIN > /dev/null
# 3: Var - 1GB
sgdisk -n 3:0:+1G -t 3:8300 -c 3:"Arch_Var" $DISK_MAIN > /dev/null
# 4: Root - User Defined
sgdisk -n 4:0:+$ROOT_SIZE -t 4:8300 -c 4:"Arch_Root" $DISK_MAIN > /dev/null

echo ">> Partitioning Home Disk: $DISK_HOME..."
sgdisk -Z $DISK_HOME > /dev/null
sgdisk -n 1:0:0 -t 1:8300 -c 1:"Arch_Home" $DISK_HOME > /dev/null

# Helper for NVMe naming (e.g., nvme0n1p1 vs sda1)
part_name() {
    local disk=$1
    local part=$2
    if [[ "$disk" =~ "nvme" ]]; then echo "${disk}p${part}"; else echo "${disk}${part}"; fi
}

P_BOOT=$(part_name $DISK_MAIN 1)
P_REC=$(part_name $DISK_MAIN 2)
P_VAR=$(part_name $DISK_MAIN 3)
P_ROOT=$(part_name $DISK_MAIN 4)
P_HOME=$(part_name $DISK_HOME 1)

partprobe $DISK_MAIN
partprobe $DISK_HOME
sleep 2

# --- 4. FORMATTING ---
echo ">> Formatting partitions..."
mkfs.fat -F32 -n "BOOT" $P_BOOT > /dev/null
mkfs.ext4 -F -L "ROOT" $P_ROOT > /dev/null
mkfs.ext4 -F -L "VAR" $P_VAR > /dev/null
mkfs.ext4 -F -L "HOME" $P_HOME > /dev/null

# --- 5. MOUNTING MAIN OS ---
echo ">> Mounting Main OS structure..."
mount $P_ROOT $MOUNT_POINT
mkdir -p $MOUNT_POINT/{boot,var,home}
mount $P_BOOT $MOUNT_POINT/boot
mount $P_VAR $MOUNT_POINT/var
mount $P_HOME $MOUNT_POINT/home

# --- 6. BUILDING RECOVERY IMAGE (THE MAGIC PART) ---
echo ">> 🛠️  Building IMMUTABLE RECOVERY System..."
echo "   (This takes time. We are bootstrapping a separate Arch install for recovery)"

rm -rf $RECOVERY_WORK_DIR
mkdir -p $RECOVERY_WORK_DIR

# We install a minimal base to the temporary directory
pacstrap -K $RECOVERY_WORK_DIR base linux linux-firmware vim networkmanager gptfdisk dosfstools > /dev/null

# Configure Recovery Fstab (Minimal)
echo "tmpfs /tmp tmpfs defaults,noatime,mode=1777 0 0" > $RECOVERY_WORK_DIR/etc/fstab

# EXTRACT KERNEL FOR UEFI
# The UEFI loader needs to see the kernel. SquashFS is not readable by systemd-boot directly.
echo ">> Extracting Recovery Kernel..."
cp $RECOVERY_WORK_DIR/boot/vmlinuz-linux $MOUNT_POINT/boot/vmlinuz-linux-recovery
cp $RECOVERY_WORK_DIR/boot/initramfs-linux.img $MOUNT_POINT/boot/initramfs-linux-recovery.img

# SQUASH IT
echo ">> Compressing Recovery System into $P_REC (SquashFS)..."
mksquashfs $RECOVERY_WORK_DIR $P_REC -comp zstd -root-owned -noappend -wildcards > /dev/null

# CLEANUP RECOVERY BUILD
rm -rf $RECOVERY_WORK_DIR

# --- 7. INSTALLING MAIN OS ---
echo ">> 🚀 Installing MAIN Arch System..."
pacstrap -K $MOUNT_POINT base linux linux-firmware vim networkmanager sudo man-db git > /dev/null

# Generate Fstab for Main
genfstab -U $MOUNT_POINT >> $MOUNT_POINT/etc/fstab

# --- 8. BOOTLOADER CONFIGURATION ---
echo ">> Configuring systemd-boot..."
bootctl --path=$MOUNT_POINT/boot install > /dev/null

# Get UUIDs
UUID_ROOT=$(blkid -s UUID -o value $P_ROOT)
UUID_REC_PART=$(blkid -s PARTUUID -o value $P_REC)

# Loader Config
cat <<EOF > $MOUNT_POINT/boot/loader/loader.conf
default  arch.conf
timeout  5
console-mode max
editor   no
EOF

# Entry: Arch Linux (Main)
cat <<EOF > $MOUNT_POINT/boot/loader/entries/arch.conf
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=UUID=$UUID_ROOT rw
EOF

# Entry: Recovery (The Custom Logic)
# Note: 'rootfstype=squashfs' is key here.
cat <<EOF > $MOUNT_POINT/boot/loader/entries/recovery.conf
title   Arch Linux Recovery (Read-Only)
linux   /vmlinuz-linux-recovery
initrd  /initramfs-linux-recovery.img
options root=PARTUUID=$UUID_REC_PART rootfstype=squashfs ro
EOF

# Windows Entry
# Windows is usually auto-detected. If not, we rely on bootctl to find it later.

# --- 9. FINAL TOUCHES ---
echo ">> Setting up basics..."

# Hostname
echo "arch-main" > $MOUNT_POINT/etc/hostname

# Timezone (Default UTC)
arch-chroot $MOUNT_POINT ln -sf /usr/share/zoneinfo/UTC /etc/localtime
arch-chroot $MOUNT_POINT hwclock --systohc

# Locale
echo "en_US.UTF-8 UTF-8" > $MOUNT_POINT/etc/locale.gen
arch-chroot $MOUNT_POINT locale-gen > /dev/null
echo "LANG=en_US.UTF-8" > $MOUNT_POINT/etc/locale.conf

# Network
arch-chroot $MOUNT_POINT systemctl enable NetworkManager > /dev/null

echo "------------------------------------------------------------------"
echo "✅ INSTALLATION COMPLETE!"
echo "------------------------------------------------------------------"
echo "You now have:"
echo "1. Arch Linux (Main)"
echo "2. Arch Linux Recovery (SquashFS/Immutable)"
echo "3. Separate Home Disk"
echo "4. Separate Var Partition"
echo ""
echo "Please set your root password now:"
arch-chroot $MOUNT_POINT passwd

echo ""
echo "Type 'reboot' to start your new system."