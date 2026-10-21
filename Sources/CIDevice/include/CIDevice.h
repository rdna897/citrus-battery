#ifndef CIDEVICE_H
#define CIDEVICE_H

#include <stdbool.h>
#include <stdint.h>

/// Thin wrapper over libimobiledevice for reading iPhone/iPad battery data.

typedef struct {
    char udid[64];
    /// Reached over WiFi (through usbmuxd) rather than USB.
    bool network;
} cid_device;

typedef enum {
    CID_OK = 0,
    CID_NOT_FOUND,
    /// Waiting for (or refused) "Trust This Computer" on the device.
    CID_NOT_TRUSTED,
    /// Device is locked with a passcode and has never been unlocked since pairing.
    CID_LOCKED,
    CID_ERROR,
} cid_status;

/// Fills up to `max` devices and returns how many there are (USB first).
int cid_list_devices(cid_device *devices, int max);

/// Binary property lists returned by `cid_read`; free each with `cid_free`.
typedef struct {
    uint8_t *info;      ///< lockdown values (DeviceName, ProductType, ProductVersion, …)
    uint32_t info_length;
    uint8_t *battery;   ///< diagnostics_relay IORegistry entry of class IOPMPowerSource
    uint32_t battery_length;
    uint8_t *gestalt;   ///< MobileGestalt answers (may be empty on newer iOS)
    uint32_t gestalt_length;
} cid_payload;

/// Connects to a device and reads its info and battery data. May show the
/// "Trust This Computer" prompt on a device that isn't paired yet.
cid_status cid_read(const char *udid, bool network, cid_payload *payload);

void cid_free_payload(cid_payload *payload);

#endif
