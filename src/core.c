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
#include <stdio.h>

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

#include <zmk/ble.h>
#include <zmk/endpoints.h>

#include "hos.h"

LOG_MODULE_REGISTER(zmk_host_output_switch, CONFIG_ZMK_LOG_LEVEL);

/*
 * How long ZMK's BLE sender gets to take a queued report. It runs on its own,
 * lower-priority thread, so it only runs once we sleep.
 */
#define BLE_SEND_GRACE K_MSEC(10)

/*
 * Releases every held key on the output we are about to leave.
 *
 * ZMK does this itself when the output changes, but over BLE the release is
 * only queued, and sent later to whichever profile is active by then. After a
 * profile change that is the new host: the old one keeps the key down and
 * repeats it for as long as it stays away. A host can switch while the user is
 * typing, so we queue the release first and let it leave before we switch.
 */
static void leave_output_unless(bool already_there) {
    if (already_there) {
        return;
    }
    bool over_ble = zmk_endpoints_selected().transport == ZMK_TRANSPORT_BLE;

    zmk_endpoints_clear_current();
    if (over_ble) {
        k_sleep(BLE_SEND_GRACE);
    }
}

static bool output_is(enum zmk_transport transport) {
    return zmk_endpoints_selected().transport == transport;
}

static int select_usb_output(void) {
    leave_output_unless(output_is(ZMK_TRANSPORT_USB));
    return zmk_endpoints_select_transport(ZMK_TRANSPORT_USB);
}

static int select_ble_output(void) {
    leave_output_unless(output_is(ZMK_TRANSPORT_BLE));
    return zmk_endpoints_select_transport(ZMK_TRANSPORT_BLE);
}

static int select_ble_profile(int profile) {
    leave_output_unless(output_is(ZMK_TRANSPORT_BLE) && zmk_ble_active_profile_index() == profile);

    int err = zmk_ble_prof_select((uint8_t)profile);

    return err != 0 ? err : zmk_endpoints_select_transport(ZMK_TRANSPORT_BLE);
}

/* The profile index written in decimal digits, or -EINVAL. */
static int parse_profile(const char *digits, size_t len) {
    int profile = 0;

    for (size_t i = 0; i < len; i++) {
        if (digits[i] < '0' || digits[i] > '9') {
            return -EINVAL;
        }
        profile = profile * 10 + (digits[i] - '0');
        /* Checked at every digit, so a long number cannot wrap around. */
        if (profile >= ZMK_BLE_PROFILE_COUNT) {
            return -EINVAL;
        }
    }
    return profile;
}

int hos_run(const char *cmd, size_t len, const struct hos_sender *sender) {
    if (len == 0) {
        return -EINVAL;
    }

    int err = 0;

    switch (cmd[0]) {
    case 'U':
    case 'u':
        err = select_usb_output();
        break;

    case 'B':
    case 'b':
        if (len == 1) {
            err = select_ble_output();
        } else {
            int profile = parse_profile(cmd + 1, len - 1);

            err = profile < 0 ? profile : select_ble_profile(profile);
        }
        break;

    case 'M':
    case 'm':
        if (len != 1) {
            err = -EINVAL;
        } else if (!sender->ble) {
            err = select_usb_output();
        } else if (sender->profile == HOS_NO_PROFILE) {
            err = -ENODEV;
        } else {
            err = select_ble_profile(sender->profile);
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

bool hos_output_is_sender(const struct hos_state *state, const struct hos_sender *sender) {
    if (!sender->ble) {
        return state->usb;
    }
    return !state->usb && sender->profile != HOS_NO_PROFILE && sender->profile == state->profile;
}

void hos_format_state(char *out, size_t size, const struct hos_state *state) {
    snprintf(out, size, "%c %d %d", state->usb ? 'U' : 'B', state->profile,
             state->connected ? 1 : 0);
}
