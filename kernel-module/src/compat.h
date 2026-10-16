/* Backport shims for building hid-playstation against 5.4 */
#include <linux/kernel.h>
#ifndef USB_DEVICE_ID_SONY_PS5_CONTROLLER
#define USB_DEVICE_ID_SONY_PS5_CONTROLLER 0x0ce6
#endif
#ifndef USB_DEVICE_ID_SONY_PS5_CONTROLLER_2
#define USB_DEVICE_ID_SONY_PS5_CONTROLLER_2 0x0df2
#endif
#ifndef USB_DEVICE_ID_SONY_PS4_CONTROLLER_DONGLE
#define USB_DEVICE_ID_SONY_PS4_CONTROLLER_DONGLE 0x0ba0
#endif
#define sysfs_emit(buf, ...) sprintf(buf, __VA_ARGS__)
