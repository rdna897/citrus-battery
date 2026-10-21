#ifndef CNVME_H
#define CNVME_H

#include <stdbool.h>
#include <stdint.h>

/// NVMe SMART health for one drive, via IOKit's public NVMeSMARTLib.
typedef struct {
    char model[64];
    char serial[32];
    char firmware[16];
    uint8_t critical_warning;
    /// Celsius (converted from the drive's kelvin).
    int16_t temperature_celsius;
    uint8_t available_spare;
    uint8_t available_spare_threshold;
    uint8_t percentage_used;
    /// Units of 512,000 bytes, per the NVMe specification.
    uint64_t data_units_read;
    uint64_t data_units_written;
    uint64_t power_cycles;
    uint64_t power_on_hours;
    uint64_t unsafe_shutdowns;
    uint64_t media_errors;
    uint64_t error_log_entries;
} cnvme_health;

/// Reads every SMART-capable NVMe drive; returns how many were written to `drives`.
int cnvme_read_all(cnvme_health *drives, int max);

#endif
