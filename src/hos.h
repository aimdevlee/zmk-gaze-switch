/*
 * Host-driven output switch: shared between the transports.
 *
 * SPDX-License-Identifier: MIT
 */

#pragma once

#include <stdbool.h>
#include <stddef.h>

/* Who sent a command. Decides what 'M' ("select me") means. */
struct hos_sender {
    bool ble;    /* false: came over USB */
    int profile; /* BLE only: the sender's profile index, or -1 if it has none */
};

struct hos_state {
    bool usb;       /* selected output is USB */
    int profile;    /* selected BLE profile */
    bool connected; /* that profile's host is connected */
};

/* Runs one command (not NUL terminated). Returns 0 or a negative errno. */
int hos_run(const char *cmd, size_t len, const struct hos_sender *from);

void hos_get_state(struct hos_state *state);

/* True when the selected output is the sender itself. */
bool hos_points_at(const struct hos_state *state, const struct hos_sender *who);
