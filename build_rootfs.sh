set -euo pipefail

OUT_IMG="rootfs.img"
IMG_SIZE="256M"
MOUNT_DIR="$(pwd)/mnt_root"
BUSYBOX_BIN="/bin/busybox"

if [ ! -x "$BUSYBOX_BIN" ]; then
  echo "Error: $BUSYBOX_BIN not found. Install busybox-static."
  exit 1
fi

echo "Cleaning..."
rm -f "$OUT_IMG"
sudo rm -rf "$MOUNT_DIR"
mkdir -p "$MOUNT_DIR"

echo "Create image $OUT_IMG ($IMG_SIZE)..."
fallocate -l $IMG_SIZE "$OUT_IMG" || dd if=/dev/zero of="$OUT_IMG" bs=1 count=0 seek=$IMG_SIZE

echo "Format ext4..."
mkfs.ext4 -F "$OUT_IMG"

echo "Mounting..."
sudo mount -o loop "$OUT_IMG" "$MOUNT_DIR"

echo "Create minimal tree..."
sudo mkdir -p "$MOUNT_DIR"/{bin,sbin,dev,proc,sys,usr,etc,root,tmp,var,lib}
sudo chmod 1777 "$MOUNT_DIR/tmp"

echo "Copy busybox..."
sudo cp "$BUSYBOX_BIN" "$MOUNT_DIR/bin/busybox"
sudo chmod +x "$MOUNT_DIR/bin/busybox"

APPS="sh ls cat echo read grep cut mount umount mkdir rmdir rm touch chmod chown mknod stty sed head tail"
for a in $APPS; do
  sudo ln -sf /bin/busybox "$MOUNT_DIR/bin/$a"
done

sudo touch "$MOUNT_DIR/etc/myos_users"
sudo chmod 600 "$MOUNT_DIR/etc/myos_users"
sudo chown root:root "$MOUNT_DIR/etc/myos_users"

sudo tee "$MOUNT_DIR/sbin/init" > /dev/null <<'EOF'
#!/bin/sh
PATH=/bin:/sbin
export PATH

DEBUG=0

mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sys /sys 2>/dev/null || true
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true

[ -e /dev/console ] || mknod -m 600 /dev/console c 5 1
[ -e /dev/null ] || mknod -m 666 /dev/null c 1 3

if [ -e /dev/console ]; then
  CONS="/dev/console"
elif [ -e /dev/tty0 ]; then
  CONS="/dev/tty0"
else
  CONS="/dev/console"
fi

exec <"${CONS}" >"${CONS}" 2>&1

GREEN='\033[32m'
ORANGE='\033[33;1m'
RESET='\033[0m'

USERS_FILE=/etc/myos_users

# вспомогалки
trim() {
  tr -d '\r' | awk '{$1=$1;print}'
}

b64encode() {
  base64 | tr -d '\n'
}

hexdump_str() {
  od -An -t x1 | tr -s ' ' | sed 's/^ *//'
}

[ -f "$USERS_FILE" ] || { touch "$USERS_FILE"; chmod 600 "$USERS_FILE"; }

user_exists() {
  [ -f "$USERS_FILE" ] || return 1
  awk -F: -v u="$1" '$1==u{exit 0}END{exit 1}' "$USERS_FILE" >/dev/null 2>&1
}

read_password_confirm_visible() {
  while true; do
    read -r -p "Password: " P1
    read -r -p "Confirm password: " P2

    P1=$(printf '%s' "$P1" | tr -d '\r')
    P2=$(printf '%s' "$P2" | tr -d '\r')

    if [ "$P1" != "$P2" ]; then
      echo "Passwords do not match. Try again."
      continue
    fi

    printf '%s' "$P1" | b64encode
    return 0
  done
}

add_user_interactive() {
  read -r -p "Add new User? (y/n): " ANSWER
  ANSWER=$(printf '%s' "$ANSWER" | tr -d '\r' | awk '{$1=$1;print}')
  case "$ANSWER" in
    y|Y)
      if user_exists "$USERNAME"; then
        echo "User already exists."
        return 1
      fi
      ENC=$(read_password_confirm_visible)
      printf '%s:%s\n' "$USERNAME" "$ENC" >> "$USERS_FILE"
      chmod 600 "$USERS_FILE"
      sync
      echo "User '$USERNAME' created."
      if [ "$DEBUG" -eq 1 ]; then
        printf 'DEBUG stored (hex): '; printf '%s' "$ENC" | hexdump_str
      fi
      return 0
      ;;
    *)
      echo "User creation aborted."
      return 1
      ;;
  esac
}

auth_flow_for_user() {
  tries=0
  while [ "$tries" -lt 5 ]; do
    if command -v stty >/dev/null 2>&1; then
      printf "Password: "
      stty -echo 2>/dev/null || true
      read -r P1
      stty echo 2>/dev/null || true
      echo
    else
      read -r -p "Password: " P1
    fi

    P1=$(printf '%s' "$P1" | tr -d '\r')
    ENC_CUR=$(printf '%s' "$P1" | b64encode)

    stored=$(awk -F: -v u="$USERNAME" '$1==u{print $2; exit}' "$USERS_FILE" 2>/dev/null || true)
    stored=$(printf '%s' "$stored" | tr -d '\r')

    if [ "$DEBUG" -eq 1 ]; then
      printf 'DEBUG entered(enc) (hex): '; printf '%s' "$ENC_CUR" | hexdump_str
      printf 'DEBUG stored (hex): '; printf '%s' "$stored" | hexdump_str
    fi

   if [ -n "$stored" ] && [ "$ENC_CUR" = "$stored" ]; then
      clear  # Очищаем экран
      printf "${ORANGE}===Workflow ${USERNAME}===${RESET}\n"
      export USER="$USERNAME"
      exec /bin/sh
      return 0
    fi

    echo "Invalid credentials."
    tries=$((tries+1))
  done
  return 1
}

clear
printf "${GREEN}===Nabla OS===${RESET}\n"

while true; do
  while :; do
    read -r -p "Enter username: " USERNAME
    USERNAME=$(printf '%s' "$USERNAME" | trim)
    if [ -z "$USERNAME" ]; then
      echo "Username cannot be empty."
      continue
    fi
    case "$USERNAME" in
      *:*)
        echo "Username cannot contain ':' character."
        continue
        ;;
    esac
    break
  done

  if ! user_exists "$USERNAME"; then
    if add_user_interactive; then
      echo "User created successfully. Please login now."
    else
      echo "No user created."
      read -r -p "Try again? (y to try another username, any other to drop to shell): " R
      case "$R" in
        y|Y) continue ;;
        *) echo "Dropping to shell."; exec /bin/sh ;;
      esac
    fi
  fi

  if auth_flow_for_user; then
    exit 0
  else
    echo "Login failed."
    read -r -p "Try another user? (y to try again, any other to drop to shell): " R
    case "$R" in
      y|Y) continue ;;
      *) echo "Dropping to shell."; exec /bin/sh ;;
    esac
  fi
done

EOF


sudo chmod +x "$MOUNT_DIR/sbin/init"

sudo mknod -m 600 "$MOUNT_DIR/dev/console" c 5 1 || true
sudo mknod -m 666 "$MOUNT_DIR/dev/null" c 1 3 || true

sudo chown -R root:root "$MOUNT_DIR"
sync
sudo umount "$MOUNT_DIR"
rmdir "$MOUNT_DIR"

echo "rootfs image created: $(pwd)/$OUT_IMG"
