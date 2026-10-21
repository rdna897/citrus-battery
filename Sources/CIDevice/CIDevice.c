#include "CIDevice.h"

#include <arpa/inet.h>
#include <ctype.h>
#include <dns_sd.h>
#include <libimobiledevice/diagnostics_relay.h>
#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/lockdown.h>
#include <plist/plist.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>

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

static cid_status read_device(idevice_t device, cid_payload *payload);

cid_status cid_read(const char *udid, bool network, cid_payload *payload) {
    memset(payload, 0, sizeof *payload);

    idevice_t device = NULL;
    enum idevice_options lookup = network ? IDEVICE_LOOKUP_NETWORK : IDEVICE_LOOKUP_USBMUX;
    if (idevice_new_with_options(&device, udid, lookup) != IDEVICE_E_SUCCESS) return CID_NOT_FOUND;
    return read_device(device, payload);
}

/// Mirror of libimobiledevice 1.4.0's private `struct idevice_private`
/// (src/idevice.h), used only to replace a network device's address.
struct cid_idevice_1_4_0 {
    char *udid;
    uint32_t mux_id;
    enum idevice_connection_type conn_type;
    void *conn_data;
    int version;
    int device_class;
};

cid_status cid_read_at(const char *udid, const char *ipv4, cid_payload *payload) {
    memset(payload, 0, sizeof *payload);
    if (strcmp(libimobiledevice_version(), "1.4.0") != 0) return CID_ERROR;

    struct sockaddr_in address;
    memset(&address, 0, sizeof address);
    address.sin_len = sizeof address;
    address.sin_family = AF_INET;
    if (inet_pton(AF_INET, ipv4, &address.sin_addr) != 1) return CID_ERROR;

    idevice_t device = NULL;
    if (idevice_new_with_options(&device, udid, IDEVICE_LOOKUP_NETWORK) != IDEVICE_E_SUCCESS) return CID_NOT_FOUND;
    struct cid_idevice_1_4_0 *raw = (struct cid_idevice_1_4_0 *)device;
    if (raw->conn_type != CONNECTION_NETWORK) {
        idevice_free(device);
        return CID_ERROR;
    }
    // conn_data is a malloc'd sockaddr that idevice_free() releases with free().
    void *replacement = malloc(sizeof address);
    if (replacement == NULL) {
        idevice_free(device);
        return CID_ERROR;
    }
    memcpy(replacement, &address, sizeof address);
    free(raw->conn_data);
    raw->conn_data = replacement;
    return read_device(device, payload);
}

static cid_status read_device(idevice_t device, cid_payload *payload) {
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
            plist_t pack = NULL;
            if (diagnostics_relay_query_ioregistry_entry(relay, NULL, "AppleSmartBatteryPack", &pack)
                    == DIAGNOSTICS_RELAY_E_SUCCESS) {
                to_binary(pack, &payload->pack, &payload->pack_length);
                plist_free(pack);
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
    plist_mem_free(payload->pack);
    plist_mem_free(payload->gestalt);
    memset(payload, 0, sizeof *payload);
}

// MARK: Bonjour lookup

typedef struct {
    char prefix[32];
    char host[256];
    uint16_t port;
    bool found_service;
    bool found_host;
    char name[256];
    char type[64];
    char domain[256];
    uint32_t interface;
    char address[64];
    bool found_address;
} cid_lookup;

static void browse_reply(DNSServiceRef ref, DNSServiceFlags flags, uint32_t interface, DNSServiceErrorType error,
                         const char *name, const char *type, const char *domain, void *context) {
    cid_lookup *lookup = context;
    if (error != kDNSServiceErr_NoError || !(flags & kDNSServiceFlagsAdd) || lookup->found_service) return;
    // Instance names look like "40:89:c2:eb:fb:44@fe80::…-supportsRP-26".
    if (strncasecmp(name, lookup->prefix, strlen(lookup->prefix)) != 0) return;
    strncpy(lookup->name, name, sizeof lookup->name - 1);
    strncpy(lookup->type, type, sizeof lookup->type - 1);
    strncpy(lookup->domain, domain, sizeof lookup->domain - 1);
    lookup->interface = interface;
    lookup->found_service = true;
}

static void resolve_reply(DNSServiceRef ref, DNSServiceFlags flags, uint32_t interface, DNSServiceErrorType error,
                          const char *fullname, const char *host, uint16_t port, uint16_t txt_length,
                          const unsigned char *txt, void *context) {
    cid_lookup *lookup = context;
    if (error != kDNSServiceErr_NoError) return;
    strncpy(lookup->host, host, sizeof lookup->host - 1);
    lookup->found_host = true;
}

static void address_reply(DNSServiceRef ref, DNSServiceFlags flags, uint32_t interface, DNSServiceErrorType error,
                          const char *host, const struct sockaddr *address, uint32_t ttl, void *context) {
    cid_lookup *lookup = context;
    if (error != kDNSServiceErr_NoError || address == NULL || address->sa_family != AF_INET) return;
    inet_ntop(AF_INET, &((const struct sockaddr_in *)address)->sin_addr, lookup->address, sizeof lookup->address);
    lookup->found_address = true;
}

/// Processes replies on `ref` until `done` is set or the timeout passes.
static void pump(DNSServiceRef ref, bool *done, int timeout_ms) {
    int fd = DNSServiceRefSockFD(ref);
    int waited = 0;
    while (!*done && waited < timeout_ms) {
        fd_set set;
        FD_ZERO(&set);
        FD_SET(fd, &set);
        struct timeval tv = {0, 100 * 1000};
        if (select(fd + 1, &set, NULL, NULL, &tv) > 0) DNSServiceProcessResult(ref);
        waited += 100;
    }
}

bool cid_resolve_ipv4(const char *wifi_mac, char *address, int address_length, int timeout_ms) {
    cid_lookup lookup;
    memset(&lookup, 0, sizeof lookup);
    snprintf(lookup.prefix, sizeof lookup.prefix, "%s@", wifi_mac);

    DNSServiceRef browse = NULL;
    if (DNSServiceBrowse(&browse, 0, 0, "_apple-mobdev2._tcp", "local.", browse_reply, &lookup) != kDNSServiceErr_NoError) {
        return false;
    }
    pump(browse, &lookup.found_service, timeout_ms);
    DNSServiceRefDeallocate(browse);
    if (!lookup.found_service) return false;

    DNSServiceRef resolve = NULL;
    if (DNSServiceResolve(&resolve, 0, lookup.interface, lookup.name, lookup.type, lookup.domain, resolve_reply,
                          &lookup) != kDNSServiceErr_NoError) {
        return false;
    }
    pump(resolve, &lookup.found_host, timeout_ms);
    DNSServiceRefDeallocate(resolve);
    if (!lookup.found_host) return false;

    DNSServiceRef query = NULL;
    if (DNSServiceGetAddrInfo(&query, 0, lookup.interface, kDNSServiceProtocol_IPv4, lookup.host, address_reply,
                              &lookup) != kDNSServiceErr_NoError) {
        return false;
    }
    pump(query, &lookup.found_address, timeout_ms);
    DNSServiceRefDeallocate(query);
    if (!lookup.found_address) return false;

    strncpy(address, lookup.address, address_length - 1);
    address[address_length - 1] = 0;
    return true;
}
