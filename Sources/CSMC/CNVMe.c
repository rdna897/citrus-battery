#include "CNVMe.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>
#include <string.h>

static void copy_string_property(io_service_t service, CFStringRef key, char *out, size_t length) {
    out[0] = 0;
    CFTypeRef value = IORegistryEntrySearchCFProperty(service, kIOServicePlane, key, kCFAllocatorDefault,
                                                      kIORegistryIterateRecursively | kIORegistryIterateParents);
    if (value == NULL) return;
    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        CFStringGetCString(value, out, (CFIndex)length, kCFStringEncodingUTF8);
    }
    CFRelease(value);
}

static bool read_one(io_service_t service, cnvme_health *health) {
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    if (IOCreatePlugInInterfaceForService(service, kIONVMeSMARTUserClientTypeID, kIOCFPlugInInterfaceID,
                                          &plugin, &score) != kIOReturnSuccess || plugin == NULL) {
        return false;
    }
    IONVMeSMARTInterface **smart = NULL;
    HRESULT result = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID), (LPVOID *)&smart);
    if (result != S_OK || smart == NULL) {
        IODestroyPlugInInterface(plugin);
        return false;
    }

    // The interface lives inside the plug-in, so read before destroying it.
    NVMeSMARTData data;
    memset(&data, 0, sizeof data);
    IOReturn read = (*smart)->SMARTReadData(smart, &data);
    (*smart)->Release(smart);
    IODestroyPlugInInterface(plugin);
    if (read != kIOReturnSuccess) return false;

    health->critical_warning = data.CRITICAL_WARNING;
    health->temperature_celsius = data.TEMPERATURE > 0 ? (int16_t)(data.TEMPERATURE - 273) : 0;
    health->available_spare = data.AVAILABLE_SPARE;
    health->available_spare_threshold = data.AVAILABLE_SPARE_THRESHOLD;
    health->percentage_used = data.PERCENTAGE_USED;
    // 128-bit counters; the upper halves are zero for any real drive.
    health->data_units_read = data.DATA_UNITS_READ[0];
    health->data_units_written = data.DATA_UNITS_WRITTEN[0];
    health->power_cycles = data.POWER_CYCLES[0];
    health->power_on_hours = data.POWER_ON_HOURS[0];
    health->unsafe_shutdowns = data.UNSAFE_SHUTDOWNS[0];
    health->media_errors = data.MEDIA_ERRORS[0];
    health->error_log_entries = data.NUM_ERROR_INFO_LOG_ENTRIES[0];
    return true;
}

int cnvme_read_all(cnvme_health *drives, int max) {
    // Match on the property itself: Apple silicon's internal SSD is an
    // IOEmbeddedNVMeBlockDevice, not an IOBlockStorageDevice subclass.
    CFMutableDictionaryRef property = CFDictionaryCreateMutable(kCFAllocatorDefault, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(property, CFSTR("NVMe SMART Capable"), kCFBooleanTrue);
    CFMutableDictionaryRef matching = CFDictionaryCreateMutable(kCFAllocatorDefault, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(matching, CFSTR(kIOPropertyMatchKey), property);
    CFRelease(property);

    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) != KERN_SUCCESS) {
        return 0;
    }
    int count = 0;
    io_service_t service;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL && count < max) {
        CFTypeRef capable = IORegistryEntryCreateCFProperty(service, CFSTR("NVMe SMART Capable"),
                                                            kCFAllocatorDefault, 0);
        bool isCapable = capable != NULL && CFGetTypeID(capable) == CFBooleanGetTypeID()
                         && CFBooleanGetValue(capable);
        if (capable != NULL) CFRelease(capable);
        if (isCapable) {
            cnvme_health *health = &drives[count];
            memset(health, 0, sizeof *health);
            copy_string_property(service, CFSTR("Model Number"), health->model, sizeof health->model);
            copy_string_property(service, CFSTR("Serial Number"), health->serial, sizeof health->serial);
            copy_string_property(service, CFSTR("Firmware Revision"), health->firmware, sizeof health->firmware);
            if (read_one(service, health)) count++;
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return count;
}
