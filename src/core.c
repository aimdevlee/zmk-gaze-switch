/*
 * Host-driven output switch: the commands.
 *
 *   U      select the USB output
 *   B      select the BLE output, keeping the current profile
 *   B<n>   select BLE profile n, then the BLE output
 *   M      select the sender: USB if the command came over USB, the sender's
 *          own BLE profile if it came over BLE
 *   ?      no change, report state
 *
 * U and ? are matched on their first character alone: the serial port has
 * always accepted trailing text there, and hosts may rely on it.
 *
 * The transports (serial.c, hid.c) receive the text and send the reply.
 *
 * SPDX-License-Identifier: MIT
 */

#include <errno.h>

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

#include <zmk/ble.h>
#include <zmk/endpoints.h>

#include "hos.h"

LOG_MODULE_REGISTER(zmk_host_output_switch, CONFIG_ZMK_LOG_LEVEL);

static int select_ble(int profile) {
    if (profile >= 0) {
        int err = zmk_ble_prof_select((uint8_t)profile);

        if (err != 0) {
            return err;
        }
    }
    return zmk_endpoints_select_transport(ZMK_TRANSPORT_BLE);
}

int hos_run(const char *cmd, size_t len, const struct hos_sender *from) {
    if (len == 0) {
        return -EINVAL;
    }

    int err = 0;

    switch (cmd[0]) {
    case 'U':
    case 'u':
        err = zmk_endpoints_select_transport(ZMK_TRANSPORT_USB);
        break;

    case 'B':
    case 'b': {
        int profile = -1;

        if (len > 1) {
            profile = 0;
            for (size_t i = 1; i < len; i++) {
                if (cmd[i] < '0' || cmd[i] > '9' || profile > 99) {
                    return -EINVAL;
                }
                profile = profile * 10 + (cmd[i] - '0');
            }
        }
        err = select_ble(profile);
        break;
    }

    case 'M':
    case 'm':
        if (len != 1) {
            err = -EINVAL;
        } else if (!from->ble) {
            err = zmk_endpoints_select_transport(ZMK_TRANSPORT_USB);
        } else if (from->profile < 0) {
            err = -ENODEV;
        } else {
            err = select_ble(from->profile);
        }
        break;

    case '?':
        break;

    default:
        err = -EINVAL;
        break;
    }

    if (err != 0) {
        LOG_WRN("command '%.*s' failed: %d", (int)len, cmd, err);
    }
    return err;
}

void hos_get_state(struct hos_state *state) {
    struct zmk_endpoint_instance ep = zmk_endpoints_selected();

    state->usb = ep.transport != ZMK_TRANSPORT_BLE;
    state->profile = zmk_ble_active_profile_index();
    state->connected = zmk_ble_active_profile_is_connected();
}

bool hos_points_at(const struct hos_state *state, const struct hos_sender *who) {
    if (!who->ble) {
        return state->usb;
    }
    return !state->usb && who->profile >= 0 && who->profile == state->profile;
}
