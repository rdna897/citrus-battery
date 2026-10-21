#include "CIDevice.h"

#include <libimobiledevice/diagnostics_relay.h>
#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/lockdown.h>
#include <plist/plist.h>
#include <stdlib.h>
#include <string.h>

int cid_list_devices(cid_device *devices, int max) {
    idevice_info_t *list = NULL;
    int count = 0;
    if (idevice_get_device_list_extended(&list, &count) != IDEVICE_E_SUCCESS) return 0;

    int written = 0;
    // USB connections first, so a device reachable both ways is read over USB.
    for (int pass = 0; pass < 2; pass++) {
        for (int i = 0; i < count && written < max; i++) {
            bool network = list[i]->conn_type == CONNECTION_NETWORK;
            if (network != (pass == 1)) continue;
            bool seen = false;
            for (int j = 0; j < written; j++) {
                if (strcmp(devices[j].udid, list[i]->udid) == 0) seen = true;
            }
            if (seen) continue;
            strncpy(devices[written].udid, list[i]->udid, sizeof(devices[written].udid) - 1);
            devices[written].udid[sizeof(devices[written].udid) - 1] = 0;
            devices[written].network = network;
            written++;
        }
    }
    idevice_device_list_extended_free(list);
    return written;
}

static void to_binary(plist_t plist, uint8_t **data, uint32_t *length) {
    *data = NULL;
    *length = 0;
    if (plist == NULL) return;
    char *bin = NULL;
    plist_to_bin(plist, &bin, length);
    *data = (uint8_t *)bin;
}

cid_status cid_read(const char *udid, bool network, cid_payload *payload) {
    memset(payload, 0, sizeof *payload);

    idevice_t device = NULL;
    enum idevice_options lookup = network ? IDEVICE_LOOKUP_NETWORK : IDEVICE_LOOKUP_USBMUX;
    if (idevice_new_with_options(&device, udid, lookup) != IDEVICE_E_SUCCESS) return CID_NOT_FOUND;

    cid_status status = CID_OK;
    lockdownd_client_t lockdown = NULL;
    lockdownd_error_t lerr = lockdownd_client_new_with_handshake(device, &lockdown, "CitrusBattery");
    switch (lerr) {
    case LOCKDOWN_E_SUCCESS:
        break;
    case LOCKDOWN_E_PASSWORD_PROTECTED:
        status = CID_LOCKED;
        goto done;
    case LOCKDOWN_E_PAIRING_DIALOG_RESPONSE_PENDING:
    case LOCKDOWN_E_USER_DENIED_PAIRING:
    case LOCKDOWN_E_INVALID_HOST_ID:
    case LOCKDOWN_E_PAIRING_FAILED:
        status = CID_NOT_TRUSTED;
        goto done;
    default:
        status = CID_ERROR;
        goto done;
    }

    plist_t info = NULL;
    if (lockdownd_get_value(lockdown, NULL, NULL, &info) == LOCKDOWN_E_SUCCESS) {
        to_binary(info, &payload->info, &payload->info_length);
        plist_free(info);
    }

    lockdownd_service_descriptor_t service = NULL;
    if (lockdownd_start_service(lockdown, DIAGNOSTICS_RELAY_SERVICE_NAME, &service) != LOCKDOWN_E_SUCCESS) {
        // Older iOS versions publish the relay under its previous name.
        lockdownd_start_service(lockdown, "com.apple.iosdiagnostics.relay", &service);
    }
    if (service != NULL && service->port > 0) {
        diagnostics_relay_client_t relay = NULL;
        if (diagnostics_relay_client_new(device, service, &relay) == DIAGNOSTICS_RELAY_E_SUCCESS) {
            plist_t battery = NULL;
            if (diagnostics_relay_query_ioregistry_entry(relay, NULL, "IOPMPowerSource", &battery)
                    == DIAGNOSTICS_RELAY_E_SUCCESS) {
                to_binary(battery, &payload->battery, &payload->battery_length);
                plist_free(battery);
            }

            static const char *keys[] = {
                "MarketingName", "DeviceColor", "SerialNumber", "ModelNumber", "RegionInfo",
                "ProductType", "ProductVersion", "UniqueChipID",
            };
            plist_t query = plist_new_array();
            for (size_t i = 0; i < sizeof keys / sizeof keys[0]; i++) {
                plist_array_append_item(query, plist_new_string(keys[i]));
            }
            plist_t gestalt = NULL;
            if (diagnostics_relay_query_mobilegestalt(relay, query, &gestalt) == DIAGNOSTICS_RELAY_E_SUCCESS) {
                to_binary(gestalt, &payload->gestalt, &payload->gestalt_length);
                plist_free(gestalt);
            }
            plist_free(query);

            diagnostics_relay_goodbye(relay);
            diagnostics_relay_client_free(relay);
        }
    }
    if (service != NULL) lockdownd_service_descriptor_free(service);

done:
    if (lockdown != NULL) lockdownd_client_free(lockdown);
    idevice_free(device);
    return status;
}

void cid_free_payload(cid_payload *payload) {
    plist_mem_free(payload->info);
    plist_mem_free(payload->battery);
    plist_mem_free(payload->gestalt);
    memset(payload, 0, sizeof *payload);
}
