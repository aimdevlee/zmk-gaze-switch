/*
 * Host-driven output switch: USB serial transport.
 *
 * The central half stays plugged into one computer over USB. That computer
 * writes the commands from core.c to a dedicated CDC ACM port, each ended by
 * '\n' or '\r', and gets a single line back:
 *
 *   ZMK-HOS 1 <U|B> <profile> <ble-connected 0|1>\n
 *   ZMK-HOS 1 ERR\n
 *
 * The first field identifies this port, so the host can tell it apart from
 * the ZMK Studio port that shares the same USB device.
 *
 * SPDX-License-Identifier: MIT
 */

#include <stdio.h>

#include <zephyr/device.h>
#include <zephyr/drivers/uart.h>
#include <zephyr/init.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/sys/ring_buffer.h>

#include "hos.h"

LOG_MODULE_DECLARE(zmk_host_output_switch, CONFIG_ZMK_LOG_LEVEL);

#define HOS_NODE DT_CHOSEN(zmk_host_output_switch_uart)

#if !DT_NODE_EXISTS(HOS_NODE)
#error "the serial transport needs the zmk,host-output-switch-uart chosen node"
#endif

#define CMD_MAX 16

static const struct device *const uart_dev = DEVICE_DT_GET(HOS_NODE);

RING_BUF_DECLARE(rx_buf, 64);
RING_BUF_DECLARE(tx_buf, 128);

static void process_rx(struct k_work *work);
static K_WORK_DEFINE(rx_work, process_rx);

static char line[CMD_MAX];
static size_t line_len;
static bool line_overflow;

static bool host_listening(void) {
    uint32_t dtr = 0;

    if (uart_line_ctrl_get(uart_dev, UART_LINE_CTRL_DTR, &dtr) != 0) {
        return false;
    }
    return dtr != 0;
}

/* Queue a reply. Dropped when nobody has the port open, so we never wait. */
static void send_reply(const char *text, size_t len) {
    if (!host_listening()) {
        return;
    }

    if (ring_buf_put(&tx_buf, (const uint8_t *)text, len) < len) {
        LOG_WRN("reply truncated, tx buffer full");
    }
    uart_irq_tx_enable(uart_dev);
}

static void run_command(const char *cmd, size_t len) {
    static const struct hos_sender usb_host = {.ble = false, .profile = -1};

    if (len == 0) {
        return;
    }

    if (hos_run(cmd, len, &usb_host) != 0) {
        static const char bad[] = "ZMK-HOS 1 ERR\n";
        send_reply(bad, sizeof(bad) - 1);
        return;
    }

    /*
     * The endpoint change is applied synchronously, but a fresh BLE profile
     * may not be connected yet; the host can poll with '?' to watch it.
     */
    struct hos_state state;
    char text[16];
    char out[48];

    hos_get_state(&state);
    hos_format_state(text, sizeof(text), &state);
    int n = snprintf(out, sizeof(out), "ZMK-HOS 1 %s\n", text);

    if (n > 0) {
        send_reply(out, MIN((size_t)n, sizeof(out) - 1));
    }
}

/* Runs on the system work queue, never in the USB interrupt. */
static void process_rx(struct k_work *work) {
    uint8_t byte;

    while (ring_buf_get(&rx_buf, &byte, 1) == 1) {
        if (byte == '\n' || byte == '\r') {
            if (!line_overflow) {
                run_command(line, line_len);
            }
            line_len = 0;
            line_overflow = false;
            continue;
        }

        if (line_len < sizeof(line)) {
            line[line_len++] = (char)byte;
        } else {
            line_overflow = true;
        }
    }
}

static void uart_isr(const struct device *dev, void *user_data) {
    while (uart_irq_update(dev) && uart_irq_is_pending(dev)) {
        if (uart_irq_rx_ready(dev)) {
            uint8_t chunk[16];
            int n = uart_fifo_read(dev, chunk, sizeof(chunk));

            if (n > 0) {
                ring_buf_put(&rx_buf, chunk, n);
                k_work_submit(&rx_work);
            }
        }

        if (uart_irq_tx_ready(dev)) {
            uint8_t *data;
            uint32_t avail = ring_buf_get_claim(&tx_buf, &data, tx_buf.size);

            if (avail == 0) {
                uart_irq_tx_disable(dev);
            } else {
                int sent = uart_fifo_fill(dev, data, avail);

                if (sent <= 0) {
                    /*
                     * Not configured or suspended: the driver drops the data
                     * but may keep reporting tx-ready. Give up on this reply
                     * rather than spin here.
                     */
                    ring_buf_get_finish(&tx_buf, 0);
                    ring_buf_reset(&tx_buf);
                    uart_irq_tx_disable(dev);
                    break;
                }
                ring_buf_get_finish(&tx_buf, sent);
            }
        }
    }
}

static int serial_init(void) {
    if (!device_is_ready(uart_dev)) {
        LOG_ERR("CDC ACM device not ready");
        return -ENODEV;
    }

    uart_irq_callback_set(uart_dev, uart_isr);
    uart_irq_rx_enable(uart_dev);

    return 0;
}

SYS_INIT(serial_init, APPLICATION, CONFIG_APPLICATION_INIT_PRIORITY);
