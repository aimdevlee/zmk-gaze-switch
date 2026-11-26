/*
 * Let bonded hosts on non-selected profiles reconnect.
 *
 * ZMK advertises only while the selected profile is open or disconnected. A
 * host on another profile that drops its link (sleep, Bluetooth off) then has
 * nothing to connect to until someone selects its profile -- which is exactly
 * the command it can no longer send. So whenever a bonded profile is
 * disconnected and ZMK is not advertising, we advertise in its place, with
 * the same parameters and data ZMK uses.
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

#define ADV_PARAM                                                                                  \
    BT_LE_ADV_PARAM(BT_LE_ADV_OPT_CONNECTABLE | BT_LE_ADV_OPT_ONE_TIME | BT_LE_ADV_OPT_USE_NAME |  \
                        BT_LE_ADV_OPT_FORCE_NAME_IN_AD,                                            \
                    BT_GAP_ADV_FAST_INT_MIN_2, BT_GAP_ADV_FAST_INT_MAX_2, NULL)

static bool started_by_us;

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
    if (!bonded_host_missing()) {
        /*
         * Nobody left to wait for (the host came back, or its bond was
         * cleared). Stop what we started, unless ZMK needs advertising for
         * the selected profile -- then it is not ours to stop.
         */
        if (started_by_us && zmk_ble_active_profile_is_connected()) {
            bt_le_adv_stop();
        }
        started_by_us = false;
        return;
    }

    int err = bt_le_adv_start(ADV_PARAM, adv_data, ARRAY_SIZE(adv_data), NULL, 0);

    if (err == 0) {
        started_by_us = true;
        LOG_DBG("advertising for a bonded host on a non-selected profile");
    } else if (err != -EALREADY) {
        LOG_WRN("advertising failed to start (%d), retrying", err);
        k_work_reschedule(&advertise_work, RETRY_DELAY);
    }
}

static void on_link_change(struct bt_conn *conn) {
    struct bt_conn_info info;

    if (bt_conn_get_info(conn, &info) == 0 && info.role == BT_CONN_ROLE_PERIPHERAL) {
        k_work_reschedule(&advertise_work, AFTER_ZMK_DELAY);
    }
}

/* The two callbacks have different signatures, so each needs its own forwarder. */
static void connected(struct bt_conn *conn, uint8_t err) { on_link_change(conn); }

static void disconnected(struct bt_conn *conn, uint8_t reason) { on_link_change(conn); }

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
