#!/system/bin/sh
# Loaded at boot via /sdcard/runin_config (runin_test service, root)
LOG=/data/local/ds5/boot.log
grep -q "^hid_playstation " /proc/modules || insmod /data/local/ds5/hid-playstation.ko >$LOG 2>&1
echo "$(date) rc=$? $(grep -c hid_playstation /proc/modules)" >>$LOG
