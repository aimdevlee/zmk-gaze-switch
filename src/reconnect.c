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
 * ZMK does not know about this. It tolerates it: if it later wants to
 * advertise itself, bt_le_adv_start() reports -EALREADY and the advertising
 * that is already running does the job; if it stops advertising, the next
 * connection or profile event brings us back here.
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
 * and on), so we advertise at that interval for a short while, then slowly
 * for as long as a host stays away.
 */
#define FAST_PERIOD_MS (30 * MSEC_PER_SEC)

/*
 * Copies of ZMK's zmk_ble_ad and ZMK_ADV_CONN_NAME in app/src/ble.c. Both are
 * private to that file, so they cannot be shared; keep them in step with it.
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

#define ADV_PARAM_FAST                                                                             \
    BT_LE_ADV_PARAM(ADV_OPTIONS, BT_GAP_ADV_FAST_INT_MIN_2, BT_GAP_ADV_FAST_INT_MAX_2, NULL)
#define ADV_PARAM_SLOW                                                                             \
    BT_LE_ADV_PARAM(ADV_OPTIONS, BT_GAP_ADV_SLOW_INT_MIN, BT_GAP_ADV_SLOW_INT_MAX, NULL)

/* Advertising that we started and, as far as we know, is still running. */
static bool started_by_us;
static bool started_fast;
/* Uptime until which a host that dropped is given the fast interval. */
static int64_t fast_until;

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
    /*
     * While the selected profile is connected ZMK wants no advertising, so
     * whatever runs is ours to stop. Otherwise it may be ZMK's by now.
     */
    bool ours_to_stop = started_by_us && zmk_ble_active_profile_is_connected();

    if (!bonded_host_missing()) {
        /* Nobody left to wait for (the host came back, or its bond was cleared). */
        if (ours_to_stop) {
            bt_le_adv_stop();
        }
        started_by_us = false;
        return;
    }

    int64_t fast_left = fast_until - k_uptime_get();
    bool fast = fast_left > 0;

    if (ours_to_stop && started_fast != fast) {
        /* Restart at the other interval. */
        bt_le_adv_stop();
        started_by_us = false;
    }

    int err = bt_le_adv_start(fast ? ADV_PARAM_FAST : ADV_PARAM_SLOW, adv_data,
                              ARRAY_SIZE(adv_data), NULL, 0);

    if (err == 0) {
        started_by_us = true;
        started_fast = fast;
        LOG_DBG("advertising %s for a bonded host on a non-selected profile",
                fast ? "fast" : "slowly");
    } else if (err != -EALREADY) {
        LOG_WRN("advertising failed to start (%d), retrying", err);
        k_work_reschedule(&advertise_work, RETRY_DELAY);
        return;
    }
    if (fast) {
        /* Come back to slow down. */
        k_work_reschedule(&advertise_work, K_MSEC(fast_left + 1));
    }
}

/* A host connected or dropped. (Links to the other half of a split keyboard are not hosts.) */
static void on_host_link_change(struct bt_conn *conn, bool dropped) {
    struct bt_conn_info info;

    if (bt_conn_get_info(conn, &info) != 0 || info.role != BT_CONN_ROLE_PERIPHERAL) {
        return;
    }
    if (dropped) {
        fast_until = k_uptime_get() + FAST_PERIOD_MS;
    }
    k_work_reschedule(&advertise_work, AFTER_ZMK_DELAY);
}

/* The two callbacks have different signatures, so each needs its own forwarder. */
static void connected(struct bt_conn *conn, uint8_t err) { on_host_link_change(conn, false); }

static void disconnected(struct bt_conn *conn, uint8_t reason) { on_host_link_change(conn, true); }

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
