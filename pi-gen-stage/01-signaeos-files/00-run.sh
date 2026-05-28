#!/bin/bash -e
# pi-gen entry point — copies and runs signaeos-install.sh inside the chroot

# Copy our install script into the chroot
install -m 755 "${STAGE_DIR}/signaeos-install.sh" "${ROOTFS_DIR}/tmp/signaeos-install.sh"

# Substitute version placeholder
sed -i "s|@@SIGNAEOS_VERSION@@|${SIGNAEOS_VERSION:-0.1.0}|g" \
  "${ROOTFS_DIR}/tmp/signaeos-install.sh"

# Run it inside the chroot via pi-gen's on_chroot helper
on_chroot << 'EOF'
bash /tmp/signaeos-install.sh
rm -f /tmp/signaeos-install.sh
EOF
