set -euo pipefail

KERNEL="$HOME/NablaOS/linux/arch/x86_64/boot/bzImage"
ROOTIMG="./rootfs.img"

if [ ! -f "$KERNEL" ]; then
  echo "Cannot find bzImage at $KERNEL"
  exit 1
fi
if [ ! -f "$ROOTIMG" ]; then
  echo "Cannot find $ROOTIMG. Run build_rootfs.sh first."
  exit 1
fi

echo "Starting QEMU (VNC :1)..."
qemu-system-x86_64 \
  -enable-kvm \
  -m 512 \
  -kernel "$KERNEL" \
  -drive file="$ROOTIMG",format=raw,if=ide,index=0 \
  -append "root=/dev/sda rw console=tty0" \
  -vga std \
  -vnc :1 \
  -net nic,model=rtl8139 -net user \
  -no-reboot
