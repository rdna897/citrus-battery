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
    uint8_t *pack;      ///< IORegistry entry of class AppleSmartBatteryPack (temperature, lifetime)
    uint32_t pack_length;
    uint8_t *gestalt;   ///< MobileGestalt answers (may be empty on newer iOS)
    uint32_t gestalt_length;
} cid_payload;

/// Connects to a device and reads its info and battery data. May show the
/// "Trust This Computer" prompt on a device that isn't paired yet.
cid_status cid_read(const char *udid, bool network, cid_payload *payload);

void cid_free_payload(cid_payload *payload);

/// Reads a WiFi device at an explicit IPv4 address instead of the address usbmuxd
/// reports. macOS's usbmuxd can hold a stale IPv6 link-local address for a device
/// (connections then fail with "No route to host") while the device is reachable
/// at its current IPv4 address. Only supported with libimobiledevice 1.4.0, the
/// version bundled with the app; returns CID_ERROR otherwise.
cid_status cid_read_at(const char *udid, const char *ipv4, cid_payload *payload);

/// Finds the device announcing itself on Bonjour (_apple-mobdev2._tcp) with the
/// given WiFi MAC address and writes its IPv4 address. Returns true on success.
bool cid_resolve_ipv4(const char *wifi_mac, char *address, int address_length, int timeout_ms);

#endif
