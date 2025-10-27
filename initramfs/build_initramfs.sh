# build_initramfs.sh
#!/usr/bin/env bash
set -euo pipefail

# Builds a minimal initramfs (initramfs.cpio.gz) containing BusyBox and
# a simple English login manager that persists users in a separate disk image.
# Also creates `users.img` (ext4 raw image) on the host and initializes it
# with an empty users file so the VM can persist users across reboots.

WORKDIR="$(pwd)/initramfs-root"
OUT="$(pwd)/initramfs.cpio.gz"
USERS_IMG="$(pwd)/users.img"
USERS_IMG_SIZE_MB=16
TMP_MOUNT="$(pwd)/mnt_users_img"

# prerequisites check
command -v cpio >/dev/null || { echo "Please install cpio"; exit 1; }
command -v mkfs.ext4 >/dev/null || { echo "Please install e2fsprogs (mkfs.ext4)"; exit 1; }
command -v busybox >/dev/null || { echo "Please install busybox-static (we will copy /bin/busybox)"; exit 1; }

# Clean
rm -rf "$WORKDIR" "$OUT" "$TMP_MOUNT"
mkdir -p "$WORKDIR"/{bin,sbin,etc,proc,sys,usr,dev}

# Copy static busybox binary (we rely on host /bin/busybox being static or compatible)
BUSYBOX_BIN=/bin/busybox
if [ ! -x "$BUSYBOX_BIN" ]; then
  echo "Can't find $BUSYBOX_BIN executable. Install busybox-static or ensure /bin/busybox exists." >&2
  exit 1
fi
cp "$BUSYBOX_BIN" "$WORKDIR/bin/busybox"
chmod +x "$WORKDIR/bin/busybox"

# Create basic applets
for app in sh mount mknod cat echo read pwd ls mkdir rm rmdir touch chmod chown stty sleep; do
  ln -sf /bin/busybox "$WORKDIR/bin/$app"
done

# create device nodes minimal (devtmpfs will usually provide them, but nice to have)
# We'll create /dev/console to be safe when running in -nographic or VNC
if [ ! -e "$WORKDIR/dev/console" ]; then
  : > "$WORKDIR/dev/console"
fi

# Create initial persistent users image (host-side)
if [ -f "$USERS_IMG" ]; then
  echo "users.img already exists, keeping it: $USERS_IMG"
else
  echo "Creating users image ($USERS_IMG) of ${USERS_IMG_SIZE_MB}MB..."
  dd if=/dev/zero of="$USERS_IMG" bs=1M count=$USERS_IMG_SIZE_MB status=progress
  # format as ext4
  mkfs.ext4 -F -q "$USERS_IMG"
  # mount, create users file
  mkdir -p "$TMP_MOUNT"
  sudo mount -o loop "$USERS_IMG" "$TMP_MOUNT"
  sudo install -m 600 /dev/null "$TMP_MOUNT/myos_users"
  sudo umount "$TMP_MOUNT"
  rmdir "$TMP_MOUNT"
  echo "Created and initialized $USERS_IMG"
fi

# Create init script (English UI, persistent users on separate disk)
cat > "$WORKDIR/init" <<'EOF'
#!/bin/sh
# Minimal init for NablaOS testing (improved diagnostics)
PATH=/bin:/sbin:/usr/bin
export PATH

# Mount pseudo filesystems
mount -t proc proc /proc || true
mount -t sysfs sys /sys || true
mount -t devtmpfs devtmpfs /dev || true

# Create console nodes if missing
[ -e /dev/console ] || mknod -m 600 /dev/console c 5 1 || true
[ -e /dev/tty1 ] || mknod -m 620 /dev/tty1 c 4 1 || true

# redirect stdio to tty1 so VNC/graphical console shows output
exec </dev/tty1 >/dev/tty1 2>&1

clear
echo "=== NablaOS (test) ==="

echo "[init] Listing devices and recent kernel messages for debugging..."
echo "--- /dev ---"
ls -la /dev || true

echo "--- /proc/partitions ---"
cat /proc/partitions || true

echo "--- dmesg tail ---"
dmesg | tail -n 40 || true

PERSIST_DIR=/persistent
USERS_FILE="$PERSIST_DIR/myos_users"

# Try to mount the users image. We will try several likely device names.
mount_persistent() {
  mkdir -p "$PERSIST_DIR"
  # candidate device nodes (try common names)
  candidates="/dev/vda /dev/sda /dev/hda /dev/hdc /dev/sdb /dev/usb1 /dev/xvdh"
  for dev in $candidates; do
    if [ -b "$dev" ]; then
      echo "[init] Found block device: $dev"
      # try mount root of device
      if mount "$dev" "$PERSIST_DIR" 2>/dev/null; then
        echo "[init] Mounted $dev -> $PERSIST_DIR"
        return 0
      fi
      # try first partition
      if mount "${dev}1" "$PERSIST_DIR" 2>/dev/null; then
        echo "[init] Mounted ${dev}1 -> $PERSIST_DIR"
        return 0
      fi
    fi
  done
  return 1
}

# attempt to mount; if fails, wait a bit and retry a few times
i=0
while [ $i -lt 10 ]; do
  if mount_persistent; then
    break
  fi
  i=$((i+1))
  echo "[init] persistent device not ready, retry #$i"
  sleep 0.5
done

# If still not mounted, create a local persistent dir on tmpfs (non-persistent)
if [ ! -d "$PERSIST_DIR" ] || ! mount | grep -q " $PERSIST_DIR "; then
  echo "[init] Warning: persistent disk not found. Users will not persist across reboots."
  mkdir -p "$PERSIST_DIR"
fi

# Ensure users file exists and secure it
if [ ! -f "$USERS_FILE" ]; then
  touch "$USERS_FILE"
  chmod 600 "$USERS_FILE"
fi

# Helper functions
read_password() {
  stty -echo || true
  printf "Password: "
  IFS= read -r pw
  stty echo || true
  printf "
"
  # strip carriage returns just in case
  pw=$(printf "%s" "$pw" | sed 's/
$//')
  printf "%s" "$pw"
}

user_exists() {
  grep -q "^$1:" "$USERS_FILE" 2>/dev/null
}

auth_user() {
  # auth: compare plaintext (demo). $1=user $2=password
  stored=$(grep "^$1:" "$USERS_FILE" 2>/dev/null | head -n1 | cut -d: -f2-)
  # strip CR/newline
  stored=$(printf "%s" "$stored" | sed 's/
$//' )
  [ "${stored}" = "$2" ]
}

create_user() {
  echo "Create a new user."
  printf "Username: "
  IFS= read -r newuser
  newuser=$(printf "%s" "$newuser" | sed 's/
$//')
  if [ -z "$newuser" ]; then
    echo "Empty name."
    return 1
  fi
  if user_exists "$newuser"; then
    echo "User already exists."
    return 1
  fi
  echo "Enter password for $newuser"
  pw=$(read_password)
  # store plaintext (demo) — do NOT use in production
  printf "%s:%s
" "$newuser" "$pw" >> "$USERS_FILE"
  chmod 600 "$USERS_FILE"
  sync || true
  echo "User $newuser created."
  return 0
}

login_loop() {
  while true; do
    echo
    printf "Username: "
    IFS= read -r username
    username=$(printf "%s" "$username" | sed 's/
$//')
    if [ -z "$username" ]; then
      echo "Empty username, try again."
      continue
    fi

    if ! user_exists "$username"; then
      echo "User '$username' not found."
      printf "Create? (y/N): "
      IFS= read -r ans
      case "$ans" in
        y|Y)
          create_user || continue
          ;;
        *) continue ;;
      esac
    fi

    echo "Enter password for $username"
    pw=$(read_password)

    if auth_user "$username" "$pw"; then
      echo
      echo "Welcome, $username!"
      # show green workspace header (English)
      echo -e "[32m=== User workspace $username ===[0m"
      export USER="$username"
      # ensure changes are written
      sync || true
      # launch shell as the logged-in environment
      /bin/sh
      echo "Session ended. Returning to login."
    else
      echo "Incorrect password. Try again."
    fi
  done
}

login_loop

# fallback
exec /bin/sh
EOF

chmod +x "$WORKDIR/init"

# Pack initramfs
# Use cpio newc format — this is the canonical initramfs format.
( cd "$WORKDIR" && find . -print0 | cpio --null -ov --format=newc ) | gzip -9 > "$OUT"

echo "Created initramfs: $OUT"
echo "Persistent users image: $USERS_IMG"

# inform next steps
cat <<EOF
Next steps:
1) Ensure your kernel bzImage path is correct when running run_qemu_vnc.sh.
2) Make the run script executable: chmod +x run_qemu_vnc.sh
3) Start VM: ./run_qemu_vnc.sh
4) Connect TigerVNC Viewer to localhost:5901

Note: passwords are stored in plaintext in $USERS_IMG (file myos_users). This is
intended for testing only. If you want hashed passwords, tell me and I will
provide a version that stores SHA256 hashes (requires sha256sum available in initramfs).
EOF

