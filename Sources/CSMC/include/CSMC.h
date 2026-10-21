#ifndef CSMC_H
#define CSMC_H

#include <stdint.h>
#include <stdbool.h>
#include "CNVMe.h"

/// Opaque handle to an open AppleSMC user-client connection (0 = closed).
typedef uint32_t csmc_connection;

/// Opens a connection to the AppleSMC service. Returns 0 on failure.
csmc_connection csmc_open(void);

void csmc_close(csmc_connection connection);

/// Reads a four-character SMC key.
/// On success writes the four-character data type (e.g. "flt ", "ui16") into
/// `type`, up to 32 value bytes into `bytes`, the value length into `size`, and
/// returns true.
bool csmc_read(csmc_connection connection, const char key[4],
               char type[4], uint8_t bytes[32], uint32_t *size);

#endif
