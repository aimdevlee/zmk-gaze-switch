/*
 * Host-driven output switch: shared between the transports.
 *
 * SPDX-License-Identifier: MIT
 */

#pragma once

#include <stdbool.h>
#include <stddef.h>

/* hos_sender.profile of a BLE host that is on no profile. */
#define HOS_NO_PROFILE (-1)

/* Who sent a command. Decides what 'M' ("select me") means. */
struct hos_sender {
    bool ble;    /* false: came over USB */
    int profile; /* BLE only: the sender's profile index, or HOS_NO_PROFILE */
};

struct hos_state {
    bool usb;       /* selected output is USB */
    int profile;    /* selected BLE profile */
    bool connected; /* that profile's host is connected */
};

/* Runs one command (not NUL terminated). Returns 0 or a negative errno. */
int hos_run(const char *cmd, size_t len, const struct hos_sender *sender);

void hos_get_state(struct hos_state *state);

/* True when the selected output is the sender itself. */
bool hos_output_is_sender(const struct hos_state *state, const struct hos_sender *sender);

/*
 * Writes "<U|B> <profile> <ble-connected 0|1>", the part of a reply that both
 * transports share.
 */
void hos_format_state(char *out, size_t size, const struct hos_state *state);
