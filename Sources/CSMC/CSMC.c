#include "CSMC.h"

#include <IOKit/IOKitLib.h>
#include <string.h>

// Layout of the AppleSMC struct-method payload (80 bytes). Field order and
// sizes must match the kernel's SMCParamStruct exactly.
typedef struct {
    uint8_t major, minor, build, reserved;
    uint16_t release;
} smc_version;

typedef struct {
    uint16_t version, length;
    uint32_t cpu_limit, gpu_limit, mem_limit;
} smc_plimit;

typedef struct {
    uint32_t data_size;
    uint32_t data_type;
    uint8_t data_attributes;
} smc_key_info;

typedef struct {
    uint32_t key;
    smc_version vers;
    smc_plimit plimit;
    smc_key_info key_info;
    uint8_t result, status, command;
    uint32_t data32;
    uint8_t bytes[32];
} smc_param;

_Static_assert(sizeof(smc_param) == 80, "unexpected SMC payload size");

enum {
    kSMCHandleYPCEvent = 2,
    kSMCReadKey = 5,
    kSMCGetKeyInfo = 9,
};

static uint32_t four_cc(const char key[4]) {
    return ((uint32_t)(uint8_t)key[0] << 24) | ((uint32_t)(uint8_t)key[1] << 16) |
           ((uint32_t)(uint8_t)key[2] << 8) | (uint32_t)(uint8_t)key[3];
}

static bool smc_call(csmc_connection connection, smc_param *input, smc_param *output) {
    size_t output_size = sizeof(smc_param);
    kern_return_t kr = IOConnectCallStructMethod(connection, kSMCHandleYPCEvent, input,
                                                 sizeof(smc_param), output, &output_size);
    return kr == KERN_SUCCESS && output->result == 0;
}

csmc_connection csmc_open(void) {
    io_service_t service =
        IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (service == IO_OBJECT_NULL) return 0;
    io_connect_t connection = 0;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &connection);
    IOObjectRelease(service);
    return kr == KERN_SUCCESS ? connection : 0;
}

void csmc_close(csmc_connection connection) {
    if (connection != 0) IOServiceClose(connection);
}

bool csmc_read(csmc_connection connection, const char key[4],
               char type[4], uint8_t bytes[32], uint32_t *size) {
    if (connection == 0) return false;

    smc_param input = {0}, output = {0};
    input.key = four_cc(key);
    input.command = kSMCGetKeyInfo;
    if (!smc_call(connection, &input, &output)) return false;

    smc_key_info info = output.key_info;
    if (info.data_size == 0 || info.data_size > 32) return false;

    memset(&input, 0, sizeof input);
    memset(&output, 0, sizeof output);
    input.key = four_cc(key);
    input.key_info.data_size = info.data_size;
    input.command = kSMCReadKey;
    if (!smc_call(connection, &input, &output)) return false;

    type[0] = (char)(info.data_type >> 24);
    type[1] = (char)(info.data_type >> 16);
    type[2] = (char)(info.data_type >> 8);
    type[3] = (char)info.data_type;
    memcpy(bytes, output.bytes, info.data_size);
    *size = info.data_size;
    return true;
}
