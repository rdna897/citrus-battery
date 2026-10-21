#ifndef CPOWERUI_H
#define CPOWERUI_H

#include <stdbool.h>
#include <stdint.h>

/// macOS charging policy, read from the private PowerUI framework.
/// All calls are read-only; nothing here changes charging behaviour.
typedef struct {
    /// PowerUI could be loaded and queried.
    bool available;
    /// Charge Limit (macOS 26.4+, Apple silicon).
    bool charge_limit_supported;
    bool charge_limit_enabled;
    uint8_t charge_limit_percent;
    /// Optimized Battery Charging.
    bool optimized_supported;
    bool optimized_enabled;
    /// Optimized charging is currently holding the charge below full.
    bool optimized_engaged;
} cpowerui_status;

/// Fills `status`. Performs synchronous XPC; call off the main thread.
void cpowerui_read_status(cpowerui_status *status);

#endif
