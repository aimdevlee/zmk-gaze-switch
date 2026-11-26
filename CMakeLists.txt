if(CONFIG_ZMK_HOST_OUTPUT_SWITCH)
  zephyr_library()
  # <zmk/ble.h> and <zmk/endpoints.h> live in the ZMK app, not in a module.
  zephyr_library_include_directories(${APPLICATION_SOURCE_DIR}/include)
  zephyr_library_sources(src/core.c)
  zephyr_library_sources_ifdef(CONFIG_ZMK_HOST_OUTPUT_SWITCH_SERIAL src/serial.c)
  zephyr_library_sources_ifdef(CONFIG_ZMK_HOST_OUTPUT_SWITCH_HID src/hid.c)
  zephyr_library_sources_ifdef(CONFIG_ZMK_HOST_OUTPUT_SWITCH_BLE_RECONNECT src/reconnect.c)
endif()
