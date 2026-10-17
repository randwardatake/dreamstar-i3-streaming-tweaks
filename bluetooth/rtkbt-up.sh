#!/system/bin/sh
# TP-Link UB500 (RTL8761BU) USB Bluetooth bring-up for Dreamstar i1.
# Runs as root (adb root). Idempotent: safe to run repeatedly.
D=/data/local/tmp/rtkbt
msg() { echo "rtkbt-up: $*"; log -t rtkbt-up "$*" 2>/dev/null; }

# 1) kernel driver (built against the box's 5.4.125 kernel, CRCs from boot_b)
grep -q '^rtk_btusb ' /proc/modules || insmod $D/rtk_btusb.ko || { msg "insmod failed"; exit 1; }
i=0; while [ ! -c /dev/rtkbt_dev ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
MAJ=$(awk '$2=="rtkbt_dev"{print $1}' /proc/devices)
[ -n "$MAJ" ] || { msg "rtkbt_dev major not found"; exit 1; }

# 2) libbt-realtek hardcodes /dev/ttyAS1 as its port, so point that node at the USB driver
if [ "$(stat -c %t:%T /dev/ttyAS1 2>/dev/null)" != "$(printf '%x:0' $MAJ)" ]; then
    rm -f /dev/ttyAS1
    mknod /dev/ttyAS1 c $MAJ 0
fi
chown bluetooth:net_bt_admin /dev/ttyAS1 /dev/rtkbt_dev
chmod 0660 /dev/ttyAS1 /dev/rtkbt_dev
chcon u:object_r:hci_attach_dev:s0 /dev/ttyAS1

# 3) HAL loads libbt-vendor.so (Allwinner auto-detect, doesn't know USB BT) -> use Realtek lib directly
grep -q ' /vendor/lib/libbt-vendor.so ' /proc/mounts || mount --bind /vendor/lib/libbt-realtek.so /vendor/lib/libbt-vendor.so
chcon u:object_r:vendor_configs_file:s0 $D/rtkbt.conf; chmod 0644 $D/rtkbt.conf
grep -q ' /vendor/etc/bluetooth/rtkbt.conf ' /proc/mounts || mount --bind $D/rtkbt.conf /vendor/etc/bluetooth/rtkbt.conf

# 4) wireless_hwinfo resets these from the (BT-less) Wi-Fi module on every boot
setprop persist.log.tag.bluetooth_vendor realtek
setprop persist.vendor.bluetooth_port /dev/ttyAS1

# 5) system_server only creates the Bluetooth service if bluetooth_support was 1 when it started
if [ "$(getprop persist.log.tag.bluetooth_support)" != 1 ] || ! service check bluetooth_manager | grep -q ': found'; then
    setprop persist.log.tag.bluetooth_support 1
    if [ "$1" = "--no-restart" ]; then
        msg "bluetooth_manager missing; framework restart needed (rerun without --no-restart)"
        exit 2
    fi
    msg "restarting framework so Bluetooth service gets created"
    stop; sleep 1; start
    i=0; while [ "$(getprop sys.boot_completed)" != 1 ] || ! service check bluetooth_manager | grep -q ': found'; do
        sleep 1; i=$((i+1)); [ $i -gt 120 ] && { msg "framework did not come back"; exit 1; }
    done
fi
svc bluetooth enable
msg "ok"
