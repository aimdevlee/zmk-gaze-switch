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
#if IS_ENABLED(CONFIG_ZMK_USB)
#include <zmk/usb.h>
#endif

#include "hos.h"

LOG_MODULE_REGISTER(zmk_host_output_switch, CONFIG_ZMK_LOG_LEVEL);

/*
 * How long ZMK's BLE sender gets to take a queued report. It runs on its own,
 * lower-priority thread, so it only runs once we sleep. Not a guarantee: a
 * sender held up by a full radio queue can take longer.
 */
#define BLE_SEND_GRACE K_MSEC(10)

static bool output_is(enum zmk_transport transport) {
    return zmk_endpoints_selected().transport == transport;
}

/*
 * Releases every held key and mouse button on the selected output, for when
 * we are about to leave it.
 *
 * ZMK does this itself when the output changes, but over BLE the release is
 * only queued, and sent later to whichever profile is active by then. After a
 * profile change that is the new host: the old one keeps the key down and
 * repeats it for as long as it stays away. A host can switch while the user is
 * typing, so we queue the release first and let it leave before we switch.
 */
static void release_held_keys(void) {
    bool over_ble = output_is(ZMK_TRANSPORT_BLE);

    zmk_endpoints_clear_current();
#if IS_ENABLED(CONFIG_ZMK_POINTING)
    /* That cleared the mouse report too, but only sent the other two. */
    zmk_endpoints_send_mouse_report();
#endif
    if (over_ble) {
        k_sleep(BLE_SEND_GRACE);
    }
}

/* Whether ZMK can send on this transport now: its is_usb_ready() and is_ble_ready(). */
static bool transport_is_ready(enum zmk_transport transport) {
    if (transport == ZMK_TRANSPORT_BLE) {
        return zmk_ble_active_profile_is_connected();
    }
#if IS_ENABLED(CONFIG_ZMK_USB)
    return zmk_usb_is_hid_ready();
#else
    return false;
#endif
}

static int select_output(enum zmk_transport transport) {
    /* ZMK only moves to a transport that is ready; otherwise the output stays. */
    if (!output_is(transport) && transport_is_ready(transport)) {
        release_held_keys();
    }
    return zmk_endpoints_select_transport(transport);
}

static int select_ble_profile(int profile) {
    /*
     * Another profile always takes the output away from the current one. From
     * USB, ZMK only moves to the profile if its host is connected.
     */
    bool leaving = output_is(ZMK_TRANSPORT_BLE) ? zmk_ble_active_profile_index() != profile
                                                : zmk_ble_profile_is_connected(profile);

    if (leaving) {
        release_held_keys();
    }

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
        err = select_output(ZMK_TRANSPORT_USB);
        break;

    case 'B':
    case 'b':
        if (len == 1) {
            err = select_output(ZMK_TRANSPORT_BLE);
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
            err = select_output(ZMK_TRANSPORT_USB);
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
