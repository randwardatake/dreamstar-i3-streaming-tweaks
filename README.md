# Dreamstar i1 (Allwinner H616) as a 4K60 HDR Moonlight box

A guide for turning the **Dreamstar i1** Android TV box (Allwinner H616 / H313, Android 12
`userdebug`) into a lightweight, low-latency game-streaming client, plus the host-side
setup used with it: a **Vibepollo** (Sunshine/Apollo fork) host on CachyOS + KDE Plasma
Wayland with an RTX 3060.

Everything was measured on real hardware. Numbers are from one box and one TV (Samsung
UE50, 4K60, HDR10), so treat them as a reference, not a promise.

**Result:** 4K60 HDR10, 10-bit HDMI output, ~22 ms measured pipeline (encode 9 ms +
network 1 ms + decode 12 ms), working USB Bluetooth with a DualSense (rumble, gyro,
touchpad, lightbar, adaptive triggers), and a debloated system that idles at ~2.5 % CPU.

> **Read before you start.** The bootloader is locked and verified boot is `green`.
> Never modify `/system`, `/vendor`, `vendor_dlkm` or `boot`: the box will not boot again
> and slot A cannot be used as a fallback. Everything in this guide lives in `/data`
> and `/sdcard` and is undone by deleting those files.

---

## Contents

| Path | What |
|---|---|
| `tv-box/runin_config` | The single boot-hook line that applies everything at boot |
| `tv-box/boot.sh` | Loads the DualSense driver |
| `bluetooth/` | Realtek USB Bluetooth driver (source + prebuilt `.ko`), bring-up script, boot helper app |
| `kernel-module/` | Backport of mainline `hid-playstation` (v6.6) to the 5.4 GKI kernel |
| `moonlight-patches/` | Moonlight Android changes (decode latency, HDR10, DualSense extras) |
| `tools/dispcfg.c` | Reads / sets the HDMI output config through `/dev/disp` (used for 10-bit) |
| `tools/fd650-write.c` | Writes text to the front-panel LED display |
| `tools/sysprof.sh` | Per-process CPU / IRQ / GPU-frequency profile over N seconds |
| `tools/extract_kcrctab.py` | Rebuilds `Module.symvers` from a kernel Image + `/proc/kallsyms` |
| `tools/fftest.c` | Minimal evdev rumble test |
| `host/` | Vibepollo config and the Proton HDR hook |

---

## 0. Know your box

| | |
|---|---|
| SoC | Allwinner H616 (sun50iw9p1), 4× Cortex-A53 up to 1512 MHz, Mali-G31 MP1 306–600 MHz |
| RAM | 1.5 GB (+ 1.1 GB zram) |
| OS | Android 12 `userdebug`, fake `google/raven` fingerprint, **32-bit userspace (armeabi-v7a)** |
| Kernel | 5.4.125 android12-5.4 GKI, Clang CFI + ThinLTO, `MODVERSIONS=y`, no forced module signing |
| Root | `adb root` works, SELinux permissive |
| Slots | Running `_b`; slot `_a` is broken (overwritten by a VAB merge) |
| PMIC | AXP1530: `dcdc1` = GPU/sys (fixed 960 mV), `dcdc2` = CPU (follows the OPP table), `dcdc3` = DDR 1.5 V |
| Wi-Fi | On-board SDIO `02E7:9086` (driver `9012p`) **receives nothing on every unit tested**; use Ethernet |
| Front panel | FD650 4-digit LED clock (`/dev/fd650_dev`), driven by `panelsrv` |

ADB over the network: the vendor `init.oranth.rc` stops `adbd` at boot unless
`persist.vendor.adb.enabled=1`. Set it once over USB together with `persist.adb.tcp.port=5555`.
Note that `ro.adb.secure=0` means **anyone on your LAN gets a root shell**. Keep the box on a
trusted network.

---

## 1. The boot hook (how anything persists)

There is no way to add an init service without touching verified partitions. The box ships
a factory test script, `/system/bin/runin.sh`, started as root on `sys.boot_completed`. It
reads `/sdcard/runin_config` and `eval`s every line that starts with `loop=`.

All tweaks in this guide are chained into **one** line in `/sdcard/runin_config`
(see `tv-box/runin_config`):

```
loop=0; <step 1>; <step 2>; ...; exit 0
```

Rules learned the hard way:

- **Append, never overwrite.** Replacing the line to add one feature silently removed the
  Bluetooth step, and Bluetooth "turned itself off" on every boot.
- End with `exit 0`, otherwise `runin.sh` continues with its own test cases
  (screen-timeout changes, memtester, reboots).
- `runin.sh` can run before the FUSE `/sdcard` mount is ready. `bluetooth/btboot` is a tiny
  app that, on `BOOT_COMPLETED`, sets `debug.runin.restart=1`, which makes init start
  `runin_test_restart` again once storage is up.

To undo everything: delete `/sdcard/runin_config` (and uninstall `tr.randward.btboot`) and
reboot.

---

## 2. Debloat and services

### 2.1 Packages

Use `pm uninstall --user 0 <pkg>`. It is reversible with `cmd package install-existing <pkg>`.
Removing the Dream/Softwinner bloat, the Google stack (GMS/GSF/Play) and unused streaming apps
took the box from 139 to 82 packages and from 556 MB to ~860 MB available RAM.

Keep the vendor memory cleaner if you like a one-click "close background apps" button:
`com.dream.memoryclean` ("dream-clean"). It only calls `killBackgroundProcesses`, contains no
network code, and freed ~80 MB in a test.

### 2.2 Services that are safe to stop

Measured with `tools/sysprof.sh 120` on an idle box. None of these are marked `critical`,
so stopping them cannot reboot the box, and `start <name>` or a reboot brings them back.

| Service | Why it can go |
|---|---|
| `wificond`, `wpa_supplicant`, `vendor.wifi_hal_legacy`, `dom2reg` + `rmmod 9012p` | Dead Wi-Fi. The driver thread `WL_CMD_THREAD` was the **#1 CPU user on an idle box** |
| `vendor.ril-daemon`, `radio_monitor-daemon` | No modem |
| `cameraserver`, `vendor.camera-provider-2-4-ext` | No camera |
| `isomountservice` | Allwinner ISO mounting |
| `update_engine` | OTA. With slot A broken, an OTA is a risk anyway |
| `incidentd`, `traced`, `traced_probes`, `storaged` | Diagnostics / statistics |
| `awlog_logcatd`, `awlog_kmsgd` | Allwinner daemons that constantly write logcat and kmsg to flash |
| `vendor.cas-hal-1-2` | Broadcast conditional access |

Also run `cmd wifi set-wifi-enabled disabled` **after** stopping `wificond`. If you stop
`wificond` while Wi-Fi is enabled, the framework's `WifiSelfRecovery` turns Wi-Fi back on.

Keep: `logd`, `statsd`, `mdnsd` (Moonlight host discovery), `multi_ir` (IR remote), CEC,
`pqd` (picture quality), DRM, `gpio`, `systemmix`, `panelsrv` (front clock).

Effect: idle CPU (busy jiffies over 120 s) 1303 → 1057 (about −19 %), +17 MB RAM.
Temperatures did **not** change (see 6), because idle heat on this box is mostly static.

### 2.3 Launcher

The stock Dream launcher idles at ~43 MB PSS and ~0.2 % of a core. Arc Launcher
(`com.omeda.arc`, an open-source FLauncher descendant, GPL-3.0) idles at ~75 MB but is much
cleaner. Use the `armeabi-v7a` APK and set it with:

```sh
adb shell cmd package set-home-activity com.omeda.arc/.MainActivity
```

The choice can reset after a framework restart, so the boot hook re-applies it and fires a
HOME intent. Disable Arc's video wallpaper and backdrop blur on this GPU.

---

## 3. USB Bluetooth (TP-Link UB500 / RTL8761BU)

The box has no working on-board Bluetooth. A TP-Link UB500 (`2357:0604`) works with:

1. `bluetooth/rtk_btusb-5.4.125-gki.ko`, Realtek's `rtk_btusb` 5.2.1 patched for 5.4 and the
   TP-Link ID. It was built with Android `clang-r416183b1` against the Orange Pi 5.4.125
   sun50iw9 tree, with CRCs taken from the real kernel's `__kcrctab`. The source is in
   `bluetooth/src`.
2. `bluetooth/rtkbt-up.sh`, which:
   - loads the module;
   - points `/dev/ttyAS1` (hard-coded in `libbt-realtek`) at the USB driver;
   - bind-mounts `libbt-realtek.so` over `libbt-vendor.so` and adds a config;
   - sets `persist.log.tag.bluetooth_support=1`, so `system_server` creates the Bluetooth
     service, and `bluetooth_vendor=realtek`;
   - enables Bluetooth.
3. The stock `/vendor` already contains `rtl8761b_fw` / `rtl8761b_config`.

Copy the files to `/data/local/tmp/rtkbt/` and add `sh /data/local/tmp/rtkbt/rtkbt-up.sh` to
the boot hook.

**Symptom of a missing boot step:** the Bluetooth toggle switches on and immediately back off.

---

## 4. Video: HDMI, HDR and 10-bit

### 4.1 Resolution

`displayd` with `persist.sys.hdmistrategy=255` (auto) picks the "perfect mode" 4096×2160,
which overscans on a 3840 panel. `persist.sys.hdmistrategy=0` makes it keep the saved mode.
Line 2 of `/Reserve0/disp_rsl.fex` is `type<<8 | mode` (`422` = HDMI, mode 34 = 3840×2160p60).

### 4.2 How to read the output state

```sh
cat /sys/class/disp/disp/attr/sys | grep mgr0
# mgr0: 3840x2160 fmt[yuv420] cs[0x107] range[limit] eotf[0x10] bits[10bits]
```

| Field | Values |
|---|---|
| `eotf` | `0x4` gamma 2.2 (SDR), **`0x10` SMPTE 2084 / PQ (HDR10)**, `0x12` HLG |
| `cs` | `0x101` BT.709, **`0x107` BT.2020 NC** |
| `bits` | `8bits` / `10bits` |

`persist.disp.device_config.hdmi` = `type,mode,format,bits,eotf,cs`, e.g. `4,34,3,1,16,263`.
The same values are stored in `/Reserve0/disp_rsl.fex` as `hdmi_config=format,bits,eotf,cs,…`.
`displayd` rewrites both from its own decision, so editing them alone does not stick.

### 4.3 HDR: keep it fixed, do not use AUTO

`persist.disp.dataspace.hdmi` selects AUTO / SDR / WCG / HDR. In AUTO (`0`), `displayd`
switches HDMI between SDR and HDR10 when an HDR layer appears. **On this box and TV, every
switch left the TV without a picture and the TV buzzed.** The stable setup is a fixed HDR10
output (`dataspace=1`, `eotf=0x10`, `cs=0x107`). HDR content (Moonlight HDR, HDR10 video) is
correct; SDR UI is shown inside the HDR container.

Restarting the composer (`vendor.hwcomposer-2-2`) to re-read display props restarts the whole
Android framework.

### 4.4 10-bit output

`displayd`'s `EdidStrategy` forces 8-bit at boot, although the TV's EDID advertises
*"10-bits/component Deep Color 4:2:0"* and lists 3840×2160@60 (VIC 97) in its 4:2:0 capability
map. 8-bit PQ shows banding in gradients.

`tools/dispcfg.c` talks to the kernel display driver directly (`DISP_DEVICE_GET_CONFIG` 0x15 /
`DISP_DEVICE_SET_CONFIG` 0x14 on `/dev/disp`) and changes only the bit depth:

```sh
armv7a-linux-androideabi31-clang -O2 -o dispcfg tools/dispcfg.c
adb push dispcfg /data/local/tmp/ && adb shell /data/local/tmp/dispcfg      # read
adb shell /data/local/tmp/dispcfg 1                                          # 10-bit
adb shell /data/local/tmp/dispcfg 0                                          # back to 8-bit
```

Put `/data/local/tmp/dispcfg 1` at the end of the boot hook. Check your TV's EDID first
(`/sys/class/hdmi/hdmi/attr/edid` → `edid-decode`). If the TV does not list 10-bit 4:2:0 at
4K60, do not do this.

Still open: whether a TV power cycle (HDMI re-negotiation) drops it back to 8-bit.

### 4.5 TV settings (biggest latency win)

On the Samsung, **HDR+ Mode** blocks **Game Mode** ("this function is not available"). Turning
HDR+ off and Game Mode on removed most of the perceived input lag. It mattered far more than
any box or host tweak. Also enable **Input Signal Plus** for the box's HDMI port, which is
needed for 4K60 HDR.

---

## 5. Moonlight

### 5.1 Decode latency: 30 ms → 7–12 ms (patch)

The CedarX HEVC stream buffer manager (`sbmFrameH265`) only closes an Annex-B access unit when
the *next* AU starts, so every frame waited one frame interval inside the decoder. The patched
Moonlight appends an Access Unit Delimiter (`00 00 00 01 46 01 50`) after each frame, only for
`OMX.allwinner.*`, and remaps the off-by-one output pts. Package `com.limelight.aud`, built
from `moonlight-patches/moonlight-aud-v12.2.patch`.

### 5.2 HDR10

The Allwinner decoder does not advertise HEVC Main10 HDR10 but decodes it.
`isHevcMain10Hdr10Supported()` returns true for `OMX.allwinner` in the patch.

### 5.3 Measured pipeline (4K60 HDR10, HEVC, 100 Mbit Ethernet)

| Stage | Time | How |
|---|---|---|
| Host encode (NVENC P1, single pass) | 9 ms | Moonlight overlay "host processing" |
| Network | 1 ms | overlay |
| Box decode (patched) | 12 ms | overlay |
| Box queue → on screen | 22 ms | `dumpsys SurfaceFlinger --latency` on the Moonlight `SurfaceView` |

The video layer is composed by HWC as `DEVICE` (overlay), not by the GPU. Frame pacing
"lowest latency" vs "balanced" made only a small difference.

### 5.4 DualSense

See `kernel-module/` (mainline `hid-playstation` backported to 5.4, with CRCs matched to the
running kernel) and the Moonlight patch (gyro, lightbar, adaptive triggers through
`/dev/hidraw`). HD haptics are not possible: Vibepollo's virtual DualSense is HID-only.

---

## 6. Thermals, CPU and GPU

- **Idle temperatures are high**: CPU ~73 °C, GPU ~75–77 °C, DDR ~72 °C, VE ~70 °C, with the
  passive trip point at 70 °C. With 97 % idle CPU, this is mostly static power plus a box that
  cannot get rid of heat. Ventilation (stand the box up, leave space, a small USB fan) helps
  more than software.
- **GPU overclocking is pointless here.** The Mali-G31 spent ~100 % of uptime at its lowest
  306 MHz, even while streaming, because video is decoded by the VE and composed as an HWC
  overlay. Raising the clock only adds heat. Its rail (`dcdc1`) is shared with the rest of
  the SoC and does not scale with frequency.
- **CPU:** OPPs 480–1032 MHz at 900 mV, 1296 at 1050 mV, 1512 at 1150 mV.
  `dev_pm_opp_add` / `dev_pm_opp_remove` are exported, so a small module could re-add the OPPs
  at lower voltages (undervolt) without touching `boot`. This is not done yet.
- While streaming: CPU/GPU/VE/DDR ~78–82 °C, no throttling observed.

---

## 7. Front panel clock (FD650)

`/vendor/bin/panelsrv` opens `/dev/fd650_dev` with `O_RDWR`, keeps it open, and writes 6
bytes every second:

```
[digit0][digit1][digit2][digit3][colon 0/1][0x08]     digits are ASCII, e.g. "1234"
```

Writes from a shell redirect (`printf … > /dev/fd650_dev`, `O_WRONLY`, reopened every time)
are accepted but **not shown**. Open with `O_RDWR` and keep the fd, as in
`tools/fd650-write.c`:

```sh
stop panelsrv; /data/local/tmp/fd650-write 1234 1; start panelsrv
```

Whether letters render is not verified yet. `panelsrv` is one of the top idle CPU users
(~0.6 % of a core), so a smarter replacement could also save CPU.

---

## 8. Host (Vibepollo on KDE Plasma Wayland)

`/var/lib/vibepollo/vibepollo.conf` (see `host/vibepollo.conf`):

```ini
encoder = nvenc
nvenc_preset = 1           # was 3
nvenc_twopass = disabled   # P3 two-pass measured 13–27 ms encode, P1 single-pass 9 ms
max_bitrate = 70000
dd_paused_virtual_display_timeout_secs = 15
dd_config_revert_on_disconnect = enabled
wayland_hdr_compatibility = enabled
```

- **Monitors / audio not restored after a stream:** `dd_config_revert_on_disconnect = enabled`.
- **File ownership:** every file in `/var/lib/vibepollo` must be `vibepollo:vibepollo`, mode
  `0600`. One root-owned backup makes the host refuse to start.
- **Session history:** `/var/lib/vibepollo/session_history/session_history.db` (SQLite) has
  per-second `encode_latency_ms`, `actual_fps`, `frame_interval_jitter_ms`, GPU %, and IDR
  counts. Low fps while GPU usage is ~1 % is normal: capture is event-driven and static
  screens send fewer frames.
- **Frame cap:** during streams Vibepollo caps Proton games to the stream fps. With in-game
  V-Sync also on, a missed frame halves the fps, so turn in-game V-Sync off.
- **HDR in Proton games:** copy `host/proton-user_settings.py` and
  `_vibepollo_frame_limiter.py` into the Proton you actually use. System Protons in
  `/usr/share/steam/compatibilitytools.d` do not get the hook automatically.

### Frame generation on RTX 30 (Yakuza Kiwami 2, Lutris + GE-Proton)

DLSS Frame Generation works on an RTX 3060 with
[dlssg_for_sm86](https://github.com/sdli1995/dlssg_for_sm86) under Proton, given:

- Install its proxy as `dxgi.dll`. Lutris already overrides `dxgi` as native, while the
  default `version.dll` proxy is not loaded.
- Set `PROTON_NVIDIA_NVCUDA=1`. Its backend runs CUDA kernels, and the default Proton
  `nvcuda.dll` is a stub ("Missing cuInit").
- Set `PROTON_DLSS_UPGRADE=0`. Otherwise Proton's `nvngx_dlssg.dll` replaces the bundled
  runtime.
- Make the files user-owned, or it cannot write its logs.

On a 60 fps stream, frame generation halves the real frame rate (30 real + 30 generated) and
makes cutscenes in Dragon Engine games run in slow motion, so leave it off when streaming.

---

## Licenses

- Moonlight patch: derivative of moonlight-android, GPLv3.
- `hid-playstation` backport and `rtk_btusb`: GPL-2.0.
- Tools and scripts in this repo: MIT.
