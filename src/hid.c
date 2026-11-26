/*
 * Host-driven output switch: vendor HID transport, over USB and BLE.
 *
 * One vendor-defined HID interface with 32-byte reports and no report ID.
 * The host writes a command from core.c as ASCII in an output report, zero
 * padded, and gets one input report back on the link it used:
 *
 *   ZMK-HOS 2 <U|B> <profile> <ble-connected 0|1> <me 0|1> <sender U|0-9|->
 *   ZMK-HOS 2 ERR
 *
 * <me> is 1 when the selected output is the sender itself. <sender> is U for
 * USB, the BLE profile the sending host is bonded on, or - for a BLE host that
 * is on no profile (<me> is then 0, and M is answered with ERR).
 *
 * Every command gets one reply. A command that arrives while too many are
 * still waiting is not run and is answered with ERR.
 *
 * Over BLE this is a second HID service next to ZMK's keyboard one. ZMK keeps
 * every bonded host connected, selected or not, so a host on a non-selected
 * profile can still write here -- that is how it takes the keyboard back. The
 * reply goes to the connection that wrote, not to the selected profile.
 *
 * SPDX-License-Identifier: MIT
 */

#include <stdio.h>
#include <string.h>

#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/conn.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/device.h>
#include <zephyr/init.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

#include <zmk/ble.h>

#include "hos.h"

LOG_MODULE_DECLARE(zmk_host_output_switch, CONFIG_ZMK_LOG_LEVEL);

#define REPORT_SIZE 32

/* Hosts find the interface by these two, so they are part of the protocol. */
#define USAGE_PAGE 0xFF9A
#define USAGE 0x01

static const uint8_t report_desc[] = {
    0x06, USAGE_PAGE & 0xFF, USAGE_PAGE >> 8, /* Usage Page (vendor) */
    0x09, USAGE,                              /* Usage */
    0xA1, 0x01,                               /* Collection (Application) */
    0x15, 0x00,                               /*   Logical Minimum (0) */
    0x26, 0xFF, 0x00,                         /*   Logical Maximum (255) */
    0x75, 0x08,                               /*   Report Size (8) */
    0x95, REPORT_SIZE,                        /*   Report Count */
    0x09, 0x01,                               /*   Usage (reply) */
    0x81, 0x02,                               /*   Input (Data,Var,Abs) */
    0x09, 0x02,                               /*   Usage (command) */
    0x91, 0x02,                               /*   Output (Data,Var,Abs) */
    0xC0,                                     /* End Collection */
};

/* One received command, queued for the system work queue. */
struct request {
    struct bt_conn *conn; /* NULL: came over USB. Holds a reference otherwise. */
    uint8_t len;
    char text[REPORT_SIZE];
};

K_MSGQ_DEFINE(requests, sizeof(struct request), 4, 4);

/*
 * Commands that found the queue full, counted per sender so each still gets
 * its ERR: one slot per BLE connection, and the last one for USB.
 */
#define DROPPED_USB CONFIG_BT_MAX_CONN
static atomic_t dropped[CONFIG_BT_MAX_CONN + 1];

static void process(struct k_work *work);
static K_WORK_DEFINE(process_work, process);

static void enqueue(struct bt_conn *conn, const uint8_t *data, size_t len) {
    struct request req = {.conn = conn != NULL ? bt_conn_ref(conn) : NULL};

    len = MIN(len, sizeof(req.text));
    memcpy(req.text, data, len);
    /* The command is the text before the zero padding. */
    req.len = strnlen(req.text, len);

    if (k_msgq_put(&requests, &req, K_NO_WAIT) != 0) {
        LOG_WRN("command dropped, queue full");
        /* We may not send from here (USB or BLE receive context); process() does. */
        atomic_inc(&dropped[conn != NULL ? bt_conn_index(conn) : DROPPED_USB]);
        if (req.conn != NULL) {
            bt_conn_unref(req.conn);
        }
    }
    k_work_submit(&process_work);
}

/* ---- USB ---------------------------------------------------------------- */

#if IS_ENABLED(CONFIG_ZMK_USB)

#include <zephyr/usb/usb_device.h>
#include <zephyr/usb/class/usb_hid.h>

#define USB_REPORT_TYPE(setup) ((setup)->wValue >> 8)
#define USB_REPORT_TYPE_OUTPUT 0x02

static const struct device *usb_dev;
static K_SEM_DEFINE(usb_in_idle, 1, 1);

static void usb_in_ready(const struct device *dev) { k_sem_give(&usb_in_idle); }

static int usb_set_report(const struct device *dev, struct usb_setup_packet *setup, int32_t *len,
                          uint8_t **data) {
    if (USB_REPORT_TYPE(setup) != USB_REPORT_TYPE_OUTPUT) {
        return -ENOTSUP;
    }
    if (*len > 0) {
        enqueue(NULL, *data, *len);
    }
    return 0;
}

static const struct hid_ops usb_ops = {
    .int_in_ready = usb_in_ready,
    .set_report = usb_set_report,
};

static void usb_reply(const char *text) {
    /*
     * Static: the USB controller reads the buffer after hid_int_ep_write()
     * returns. usb_in_idle keeps a second reply from overwriting it mid-send.
     */
    static uint8_t report[REPORT_SIZE];

    if (usb_dev == NULL) {
        return;
    }
    /*
     * Wait for the previous reply to leave, but not forever: if that transfer
     * was cancelled (cable pulled), nobody gives the semaphore back.
     */
    k_sem_take(&usb_in_idle, K_MSEC(50));
    memset(report, 0, sizeof(report));
    memcpy(report, text, MIN(strlen(text), sizeof(report)));

    if (hid_int_ep_write(usb_dev, report, sizeof(report), NULL) != 0) {
        k_sem_give(&usb_in_idle);
    }
}

static int usb_init(void) {
    usb_dev = device_get_binding(CONFIG_ZMK_HOST_OUTPUT_SWITCH_HID_USB_DEVICE);
    if (usb_dev == NULL) {
        LOG_ERR("USB HID device %s not found; is CONFIG_USB_HID_DEVICE_COUNT at least 2?",
                CONFIG_ZMK_HOST_OUTPUT_SWITCH_HID_USB_DEVICE);
        return -ENODEV;
    }

    usb_hid_register_device(usb_dev, report_desc, sizeof(report_desc), &usb_ops);
    return usb_hid_init(usb_dev);
}

/* Before ZMK enables USB (CONFIG_ZMK_USB_INIT_PRIORITY), so the interface is in the descriptor. */
SYS_INIT(usb_init, APPLICATION, CONFIG_APPLICATION_INIT_PRIORITY);

#else

static void usb_reply(const char *text) {}

#endif /* IS_ENABLED(CONFIG_ZMK_USB) */

/* ---- BLE: a second HID service ------------------------------------------- */

enum {
    HIDS_REMOTE_WAKE = BIT(0),
    HIDS_NORMALLY_CONNECTABLE = BIT(1),
};

struct hids_info {
    uint16_t version;
    uint8_t code;
    uint8_t flags;
} __packed;

struct hids_report {
    uint8_t id;
    uint8_t type;
} __packed;

enum {
    HIDS_INPUT = 0x01,
    HIDS_OUTPUT = 0x02,
};

static const struct hids_info ble_info = {
    .version = 0x0000,
    .code = 0x00,
    .flags = HIDS_NORMALLY_CONNECTABLE | HIDS_REMOTE_WAKE,
};

static const struct hids_report ble_reply_ref = {.id = 0, .type = HIDS_INPUT};
static const struct hids_report ble_command_ref = {.id = 0, .type = HIDS_OUTPUT};

static ssize_t read_info(struct bt_conn *conn, const struct bt_gatt_attr *attr, void *buf,
                         uint16_t len, uint16_t offset) {
    return bt_gatt_attr_read(conn, attr, buf, len, offset, &ble_info, sizeof(ble_info));
}

static ssize_t read_report_map(struct bt_conn *conn, const struct bt_gatt_attr *attr, void *buf,
                               uint16_t len, uint16_t offset) {
    return bt_gatt_attr_read(conn, attr, buf, len, offset, report_desc, sizeof(report_desc));
}

static ssize_t read_report_ref(struct bt_conn *conn, const struct bt_gatt_attr *attr, void *buf,
                               uint16_t len, uint16_t offset) {
    return bt_gatt_attr_read(conn, attr, buf, len, offset, attr->user_data,
                             sizeof(struct hids_report));
}

static ssize_t read_empty_report(struct bt_conn *conn, const struct bt_gatt_attr *attr, void *buf,
                                 uint16_t len, uint16_t offset) {
    static const uint8_t empty[REPORT_SIZE];

    return bt_gatt_attr_read(conn, attr, buf, len, offset, empty, sizeof(empty));
}

static ssize_t write_command(struct bt_conn *conn, const struct bt_gatt_attr *attr, const void *buf,
                             uint16_t len, uint16_t offset, uint8_t flags) {
    if (offset != 0) {
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_OFFSET);
    }
    if (len > 0) {
        enqueue(conn, buf, len);
    }
    return len;
}

static ssize_t write_ctrl_point(struct bt_conn *conn, const struct bt_gatt_attr *attr,
                                const void *buf, uint16_t len, uint16_t offset, uint8_t flags) {
    return len;
}

/* attrs[5] is the reply characteristic; ble_reply() notifies on it. */
BT_GATT_SERVICE_DEFINE(
    hos_hog_svc, BT_GATT_PRIMARY_SERVICE(BT_UUID_HIDS),
    BT_GATT_CHARACTERISTIC(BT_UUID_HIDS_INFO, BT_GATT_CHRC_READ, BT_GATT_PERM_READ, read_info, NULL,
                           NULL),
    BT_GATT_CHARACTERISTIC(BT_UUID_HIDS_REPORT_MAP, BT_GATT_CHRC_READ, BT_GATT_PERM_READ_ENCRYPT,
                           read_report_map, NULL, NULL),

    BT_GATT_CHARACTERISTIC(BT_UUID_HIDS_REPORT, BT_GATT_CHRC_READ | BT_GATT_CHRC_NOTIFY,
                           BT_GATT_PERM_READ_ENCRYPT, read_empty_report, NULL, NULL),
    BT_GATT_CCC(NULL, BT_GATT_PERM_READ_ENCRYPT | BT_GATT_PERM_WRITE_ENCRYPT),
    BT_GATT_DESCRIPTOR(BT_UUID_HIDS_REPORT_REF, BT_GATT_PERM_READ_ENCRYPT, read_report_ref, NULL,
                       (void *)&ble_reply_ref),

    BT_GATT_CHARACTERISTIC(BT_UUID_HIDS_REPORT,
                           BT_GATT_CHRC_READ | BT_GATT_CHRC_WRITE | BT_GATT_CHRC_WRITE_WITHOUT_RESP,
                           BT_GATT_PERM_READ_ENCRYPT | BT_GATT_PERM_WRITE_ENCRYPT, read_empty_report,
                           write_command, NULL),
    BT_GATT_DESCRIPTOR(BT_UUID_HIDS_REPORT_REF, BT_GATT_PERM_READ_ENCRYPT, read_report_ref, NULL,
                       (void *)&ble_command_ref),

    BT_GATT_CHARACTERISTIC(BT_UUID_HIDS_CTRL_POINT, BT_GATT_CHRC_WRITE_WITHOUT_RESP,
                           BT_GATT_PERM_WRITE, NULL, write_ctrl_point, NULL));

static void ble_reply(struct bt_conn *conn, const char *text) {
    uint8_t report[REPORT_SIZE] = {0};

    memcpy(report, text, MIN(strlen(text), sizeof(report)));

    int err = bt_gatt_notify(conn, &hos_hog_svc.attrs[5], report, sizeof(report));

    if (err != 0) {
        LOG_DBG("reply not sent: %d", err);
    }
}

/* ---- both ---------------------------------------------------------------- */

static const char rejected[] = "ZMK-HOS 2 ERR";

static void reject_dropped_ble(struct bt_conn *conn, void *data) {
    for (atomic_val_t n = atomic_clear(&dropped[bt_conn_index(conn)]); n > 0; n--) {
        ble_reply(conn, rejected);
    }
}

static void reject_dropped(void) {
    for (atomic_val_t n = atomic_clear(&dropped[DROPPED_USB]); n > 0; n--) {
        usb_reply(rejected);
    }
    bt_conn_foreach(BT_CONN_TYPE_LE, reject_dropped_ble, NULL);
}

static void process(struct k_work *work) {
    struct request req;

    while (k_msgq_get(&requests, &req, K_NO_WAIT) == 0) {
        struct hos_sender from = {.ble = req.conn != NULL, .profile = -1};

        if (req.conn != NULL) {
            int index = zmk_ble_profile_index(bt_conn_get_dst(req.conn));

            from.profile = index >= 0 ? index : -1;
        }

        char out[REPORT_SIZE + 1];

        if (hos_run(req.text, req.len, &from) != 0) {
            snprintf(out, sizeof(out), "%s", rejected);
        } else {
            struct hos_state state;
            char sender[4] = "-";

            hos_get_state(&state);
            if (!from.ble) {
                snprintf(sender, sizeof(sender), "U");
            } else if (from.profile >= 0) {
                snprintf(sender, sizeof(sender), "%d", from.profile % 100);
            }
            snprintf(out, sizeof(out), "ZMK-HOS 2 %c %d %d %d %s", state.usb ? 'U' : 'B',
                     state.profile, state.connected ? 1 : 0, hos_points_at(&state, &from) ? 1 : 0,
                     sender);
        }

        if (req.conn != NULL) {
            ble_reply(req.conn, out);
            bt_conn_unref(req.conn);
        } else {
            usb_reply(out);
        }
    }
    /* After the queued ones: the dropped commands arrived later. */
    reject_dropped();
}
