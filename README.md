# Linux PC → Android TV box game streaming setup

Notes, patches and tools from tuning a **Vibepollo** host (a Sunshine/Apollo fork) on a
CachyOS + KDE Plasma Wayland PC (RTX 3060) streaming to a **Dreamstar i1** TV box
(Allwinner H616, Android 12) with Moonlight at 4K60 HDR.

What this setup achieves:

- Monitors and audio come back correctly after a stream ends.
- HEVC decode latency on the box dropped from about 30 ms to about 7 ms.
- HDR10 works on the box's decoder.
- The TV gets a stable 3840x2160p60 output, so the image no longer overscans.
- A DualSense / DualSense Edge on the box gets rumble, gyro, touchpad, lightbar and
  adaptive-trigger support.
- Proton games see HDR during HDR streams.

> Everything here is specific to this hardware. Read it before applying it, and keep backups.

---

## Contents

| Path | What |
|---|---|
| `moonlight-patches/moonlight-aud-v12.2.patch` | All Moonlight Android changes, against upstream tag `v12.2` |
| `kernel-module/` | Backport of mainline `hid-playstation` (v6.6) to the box's 5.4 GKI kernel, with a prebuilt `.ko` |
| `tools/extract_kcrctab.py` | Rebuilds `Module.symvers` (symbol CRCs) from a kernel Image plus `/proc/kallsyms` |
| `tools/fftest.c` | Minimal evdev force-feedback rumble test |
| `tv-box/` | Boot-time hook used to load the module persistently |
| `host/` | Vibepollo config and the Proton `user_settings.py` hook |

---

## 1. Host (Vibepollo on KDE Wayland)

`/var/lib/vibepollo/vibepollo.conf`:

```ini
encoder = nvenc
dd_paused_virtual_display_timeout_secs = 15
dd_config_revert_on_disconnect = enabled
max_bitrate = 70000
nvenc_preset = 3
wayland_hdr_compatibility = enabled
```

- **Displays and audio not restored after a stream.** A Moonlight disconnect only
  *pauses* the session, so Vibepollo kept the virtual display (`Virtual-1`) and its
  audio sink. The physical monitors stayed off until a TTY switch.
  `dd_config_revert_on_disconnect = enabled` restores the topology and the default
  sink on disconnect.
- **Bitrate.** An iperf3 UDP test to the box was clean up to about 95 Mbps (the box
  has 100 Mbit Ethernet), so the cap is set to 70 Mbps. `nvenc_preset = 3` trades a
  little quality for lower encode time.
- **File ownership.** Every file in `/var/lib/vibepollo` must be owned by
  `vibepollo:vibepollo` with mode `0600`. A single root-owned file (even a backup) makes
  `vibepollo-machine-host` refuse to start with "machine profile permissions are unsafe".
- **Restarting.** `systemctl restart vibepollo.service` is fine; the
  `vibepollo-session-controller` rebinds it to the Plasma session.

### HDR in Proton games (e.g. God of War)

Vibepollo injects HDR variables into Proton launches during HDR streams:
`PROTON_ENABLE_HDR`, `DXVK_HDR`, plus `PROTON_ENABLE_WAYLAND` and `ENABLE_HDR_WSI` when
`wayland_hdr_compatibility` is on.

It does this through a `user_settings.py` hook that is only written into Proton
installs under `~/.local/share/Steam/compatibilitytools.d`. Steam's default tool here,
`proton-cachyos-slr`, lives in `/usr/share/steam/compatibilitytools.d`. That copy
never got the hook, so games using it never saw HDR.

Fix:

1. Copy the hook (`host/proton-user_settings.py` and `_vibepollo_frame_limiter.py`)
   into the system Proton directory.
2. Enable `wayland_hdr_compatibility`. Without the Wayland driver, games on XWayland
   cannot see HDR.

The hook asks the running Vibepollo over a Unix socket, so outside a stream it does
nothing. The two `.py` files are not owned by the package, so they survive Proton
updates.

### Yakuza Kiwami 2 (2025 update, Lutris, GE-Proton)

The 2025 update added DLSS and FSR. `PROTON_DLSS_UPGRADE=1` in the Lutris game env
pulls the newest DLSS DLL. DLSS Frame Generation is not supported on RTX 30-series
cards.

---

## 2. TV box (Dreamstar i1 / Allwinner H616 / Android 12 userdebug)

The box is `userdebug` with `adb root`, SELinux is permissive and the active slot is
`_b`.

**The bootloader is locked and verified boot is `green`.** Do not modify `/system`,
`/vendor`, `vendor_dlkm` or `boot`: the box will not boot. Everything below lives in
`/data`.

### 2.1 HDMI output overscan / wrong resolution

`displayd` with `persist.sys.hdmistrategy=255` (auto) always picks the "perfect mode"
4096x2160, which overscans on the TV. A non-255 strategy makes it reuse the saved mode
instead:

```sh
adb shell setprop persist.sys.hdmistrategy 0
# saved mode 34 = 3840x2160p60 (line 2 of /Reserve0/disp_rsl.fex = 0x422)
```

After a reboot the log shows `hdmi user strategy: 0` and `hdmi output mode(34) 3840x2160`.

### 2.2 Decode latency: 30 ms → 7 ms (Moonlight patch)

**Root cause.** The CedarX HEVC stream buffer manager (`sbmFrameH265`) only closes an
Annex-B access unit when it sees the *next* AU: the next frame's first slice, or a
VPS/SPS/PPS/AUD/SEI NAL. Every frame therefore sat in the decoder until the following
frame arrived, which costs a full frame of latency plus jitter.

**Fix.** Moonlight appends an Access Unit Delimiter (`00 00 00 01 46 01 50`) after each
frame it submits, but only for `OMX.allwinner.*` decoders. The AUD closes the AU
immediately.

The decoder then stamps each output with the pts of the *previous* input (the AUD's
pts). Moonlight keeps a small map from that pts to the real one and fixes the output
timestamps, so frame pacing and the stats overlay stay correct.

### 2.3 HDR10 "not supported" (Moonlight patch)

The Allwinner decoder does not advertise the HEVC Main10 HDR10 profile even though it
decodes it fine. `isHevcMain10Hdr10Supported()` now returns true for `OMX.allwinner`.

### 2.4 DualSense on a 5.4 kernel (kernel module)

The box's kernel (5.4.125, android12-5.4 GKI, Clang CFI + ThinLTO) has no
`hid-playstation` driver. A DualSense is bound by `hid-generic`, so it has buttons and
sticks but no rumble, motion sensors, touchpad or battery reporting.

**Backport build:**

1. Pull the kernel source and toolchain:
   - kernel: `kernel/common` branch `android12-5.4`, with `SUBLEVEL` set to `125`;
   - compiler: AOSP `clang-r416183b`, the same LLVM commit the box kernel was built
     with. CFI modules must match the compiler.
2. Configure it with the box's `/proc/config.gz`, plus
   `CONFIG_ANDROID_KABI_RESERVE=y` and `CONFIG_ANDROID_VENDOR_OEM_DATA=y`. With those,
   genksyms CRCs for hid-core, input, ff-memless and driver-core match the running
   kernel exactly, so struct layouts are identical.
3. Pull the running slot's `boot_b` and extract the kernel Image. Generate
   `Module.symvers` with `tools/extract_kcrctab.py`.
4. Patch v6.6 `hid-playstation.c` (`kernel-module/src/hid-playstation-5.4-backport.patch`
   and `compat.h`):
   - 5.4 has no LED multicolor class, so a failed lightbar LED registration is non-fatal
     (the lightbar is driven from userspace instead, see 2.5);
   - force-feedback support is compiled in with `-DCONFIG_PLAYSTATION_FF=1`;
   - a `ds5_debug` module parameter logs every output report.

   Then build:

```sh
make -C ack12 ARCH=arm64 LLVM=1 LLVM_IAS=1 CROSS_COMPILE=aarch64-linux-gnu- \
     M=$PWD/src KDIR=$PWD/ack12 modules
```

**Persistence without touching verified partitions.** The factory test script
`/system/bin/runin.sh` runs as root (shell domain) on `sys.boot_completed`. It reads
`/sdcard/runin_config` and `eval`s any `loop=` line. The single line in
`tv-box/runin_config` makes it run `/data/local/ds5/boot.sh`, which `insmod`s the
module. Keep any test-case lines out of that file, or the script will run its
memtester/reboot tests.

**Key layout.** Android has no layout for the Edge (product `0df2`).
`/data/system/devices/keylayout/Vendor_054c_Product_0df2.kl` is a copy of the stock
`Vendor_054c_Product_0ce6.kl`. It maps the triggers correctly and declares the
accelerometer and gyro axes.

**Result.** Android reports the pad as `GAMEPAD | VIBRATOR` and the motion device as
`SENSOR`, with the touchpad as a separate device.

### 2.5 Moonlight: gyro, lightbar and adaptive triggers (Moonlight patch)

- **Gyro / accelerometer.** Upstream defaults the motion-sensor option to off on
  Android 12 because of a framework NPE in `InputDeviceSensorManager`. The patch
  installs an uncaught-exception filter that swallows only that NPE on non-main threads,
  so the option can be enabled (`checkbox_gamepad_motion_sensors=true`).
- **Lightbar and adaptive triggers.** These are handled by the new class
  `DualSenseHidraw.java`:
  - it finds the controller's `/dev/hidrawN`, which Android's ueventd already makes
    `0666`;
  - it writes DualSense output reports directly: BT report `0x31` with CRC32 seeded by
    `0xA2`, or USB report `0x02`;
  - only the relevant valid-flags are set, so these reports never fight the kernel
    driver's rumble reports.
- **Lightbar color.** Host `setControllerLED` events now reach the controller, and
  the RGB-LED capability is advertised to the host.
- **Adaptive triggers.** `moonlight-common-c` already parsed Sunshine's `0x5503`
  packets, but the Android app never registered the callback. The patch wires it through
  JNI (`BridgeClSetAdaptiveTriggers`), `MoonBridge` and `NvConnectionListener` into
  `ControllerHandler`. When the stream ends, the triggers are reset (effect `0x05`, off).

**HD haptics are not possible on this stack.** Games send HD haptics as channels 3–4
of the DualSense USB audio device. Vibepollo's virtual DualSense is HID-only, the
Moonlight protocol has no haptics stream, and the Bluetooth haptics report format is
still being reverse-engineered.

### 2.6 Build the patched Moonlight

```sh
git clone https://github.com/moonlight-stream/moonlight-android && cd moonlight-android
git checkout v12.2 && git submodule update --init --recursive
git apply ../moonlight-patches/moonlight-aud-v12.2.patch
./gradlew assembleNonRootRelease   # JDK 21, SDK platform 37, NDK 29
zipalign -p 4 app/build/outputs/apk/nonRoot/release/app-nonRoot-release-unsigned.apk aligned.apk
apksigner sign --ks <your.jks> --out moonlight-aud.apk aligned.apk
```

The package is `com.limelight.aud`, so it installs next to the official app. To reuse
an existing pairing, copy `client.crt`, `client.key`, `uniqueid` and `computers4.db`
from `com.limelight`.

### 2.7 Thermals (for reference)

While streaming 4K60 HDR, the CPU, GPU, video engine and DDR all sit at about
78–82 °C. The first passive trip point is at 70 °C and critical is at 115 °C. No
throttling was observed, and clocks are stock (CPU up to 1512 MHz, GPU up to 600 MHz,
VE 696 MHz).

---

## Licenses

- The Moonlight patch is a derivative of moonlight-android and is GPLv3.
- `hid-playstation` and its backport are GPL-2.0.
- The tools in this repo are MIT.
