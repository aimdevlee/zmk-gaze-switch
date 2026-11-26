/*
 * Let bonded hosts on non-selected profiles reconnect.
 *
 * ZMK advertises only while the selected profile is open or disconnected. A
 * host on another profile that drops its link (sleep, Bluetooth off) then has
 * nothing to connect to until someone selects its profile -- which is exactly
 * the command it can no longer send. So whenever a bonded profile is
 * disconnected and ZMK is not advertising, we advertise in its place, with
 * the same data ZMK uses.
 *
 * ZMK does not know about this. If it wants to advertise while we already do,
 * its bt_le_adv_start() reports -EALREADY and it does not try again, so from
 * then on our advertising also serves the selected profile: we keep it at
 * ZMK's interval for as long as ZMK wants any. If ZMK stops advertising, the
 * next connection or profile event brings us back here.
 *
 * Pairing is not affected. ZMK still rejects pairing unless the selected
 * profile is open.
 *
 * SPDX-License-Identifier: MIT
 */

#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/conn.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

#include <zmk/ble.h>
#include <zmk/event_manager.h>
#include <zmk/events/ble_active_profile_changed.h>

LOG_MODULE_DECLARE(zmk_host_output_switch, CONFIG_ZMK_LOG_LEVEL);

/* Long enough for ZMK's own advertising update, which the same events trigger, to run first. */
#define AFTER_ZMK_DELAY K_MSEC(500)
#define RETRY_DELAY K_SECONDS(2)

/*
 * Advertising shares the radio with the links that carry keys and pointer
 * movement, and at ZMK's interval it makes a trackball visibly lag. A host
 * that just dropped is likely to come straight back (Bluetooth switched off
 * and on), so it gets that interval for a short while. After that we advertise
 * slowly, unless ZMK wants advertising for the selected profile.
 */
#define FAST_PERIOD K_SECONDS(30)

/*
 * Copy of ZMK's zmk_ble_ad in app/src/ble.c. It is private to that file, so
 * it cannot be shared; keep it in step.
 */
static const struct bt_data adv_data[] = {
    BT_DATA_BYTES(BT_DATA_GAP_APPEARANCE, 0xC1, 0x03),
    BT_DATA_BYTES(BT_DATA_FLAGS, (BT_LE_AD_GENERAL | BT_LE_AD_NO_BREDR)),
    BT_DATA_BYTES(BT_DATA_UUID16_SOME, 0x12, 0x18, /* HID Service */
                  0x0f, 0x18                       /* Battery Service */
                  ),
};

#define ADV_OPTIONS                                                                                \
    (BT_LE_ADV_OPT_CONNECTABLE | BT_LE_ADV_OPT_ONE_TIME | BT_LE_ADV_OPT_USE_NAME |                 \
     BT_LE_ADV_OPT_FORCE_NAME_IN_AD)

/* The same as ZMK's ZMK_ADV_CONN_NAME, also private to ble.c. */
#define ADV_PARAM_FAST                                                                             \
    BT_LE_ADV_PARAM(ADV_OPTIONS, BT_GAP_ADV_FAST_INT_MIN_2, BT_GAP_ADV_FAST_INT_MAX_2, NULL)
#define ADV_PARAM_SLOW                                                                             \
    BT_LE_ADV_PARAM(ADV_OPTIONS, BT_GAP_ADV_SLOW_INT_MIN, BT_GAP_ADV_SLOW_INT_MAX, NULL)

enum pace {
    NOT_ADVERTISING,
    FAST,
    SLOW,
};

/* The advertising that we started and, as far as we know, is still running. */
static enum pace ours;
/* Until when a host that dropped is given the fast interval. */
static k_timepoint_t fast_until;

static bool bonded_host_missing(void) {
    for (int i = 0; i < ZMK_BLE_PROFILE_COUNT; i++) {
        if (!zmk_ble_profile_is_open(i) && !zmk_ble_profile_is_connected(i)) {
            return true;
        }
    }
    return false;
}

static void advertise_for_missing_host(struct k_work *work);
static K_WORK_DELAYABLE_DEFINE(advertise_work, advertise_for_missing_host);

static void advertise_for_missing_host(struct k_work *work) {
    /* ZMK wants advertising exactly while the selected profile has no host. */
    bool zmk_wants_some = !zmk_ble_active_profile_is_connected();
    bool in_fast_period = !sys_timepoint_expired(fast_until);

    if (!zmk_wants_some && !bonded_host_missing()) {
        /* Nobody left to wait for (the host came back, or its bond was cleared). */
        if (ours != NOT_ADVERTISING) {
            bt_le_adv_stop();
        }
        ours = NOT_ADVERTISING;
        return;
    }

    enum pace wanted = (zmk_wants_some || in_fast_period) ? FAST : SLOW;

    if (ours != NOT_ADVERTISING && ours != wanted) {
        /*
         * Restart at the other interval. What runs may be ZMK's by now, but
         * only when we want FAST, which is what ZMK's is: we start the same
         * again right below, and retry if that fails.
         */
        bt_le_adv_stop();
        ours = NOT_ADVERTISING;
    }

    int err = bt_le_adv_start(wanted == FAST ? ADV_PARAM_FAST : ADV_PARAM_SLOW, adv_data,
                              ARRAY_SIZE(adv_data), NULL, 0);

    if (err == 0) {
        ours = wanted;
        LOG_DBG("advertising %s for a host that is away", wanted == FAST ? "fast" : "slowly");
    } else if (err != -EALREADY) {
        LOG_WRN("advertising failed to start (%d), retrying", err);
        k_work_reschedule(&advertise_work, RETRY_DELAY);
        return;
    }
    if (!zmk_wants_some && in_fast_period) {
        /* Come back when the fast period ends, to slow down. */
        k_work_reschedule(&advertise_work, sys_timepoint_timeout(fast_until));
    }
}

/* Links to the other half of a split keyboard are not hosts. */
static bool is_host_link(struct bt_conn *conn) {
    struct bt_conn_info info;

    return bt_conn_get_info(conn, &info) == 0 && info.role == BT_CONN_ROLE_PERIPHERAL;
}

static void connected(struct bt_conn *conn, uint8_t err) {
    if (!is_host_link(conn)) {
        return;
    }
    if (err == 0) {
        /* Our advertising is one-time: a connection ends it. */
        ours = NOT_ADVERTISING;
    }
    k_work_reschedule(&advertise_work, AFTER_ZMK_DELAY);
}

static void disconnected(struct bt_conn *conn, uint8_t reason) {
    if (!is_host_link(conn)) {
        return;
    }
    fast_until = sys_timepoint_calc(FAST_PERIOD);
    k_work_reschedule(&advertise_work, AFTER_ZMK_DELAY);
}

BT_CONN_CB_DEFINE(hos_reconnect_conn_cb) = {
    .connected = connected,
    .disconnected = disconnected,
};

/* Raised on profile selection, and when a profile's bond is set or cleared. */
static int on_profile_changed(const zmk_event_t *eh) {
    k_work_reschedule(&advertise_work, AFTER_ZMK_DELAY);
    return ZMK_EV_EVENT_BUBBLE;
}

ZMK_LISTENER(hos_reconnect, on_profile_changed);
ZMK_SUBSCRIPTION(hos_reconnect, zmk_ble_active_profile_changed);
