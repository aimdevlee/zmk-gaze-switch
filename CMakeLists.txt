if(CONFIG_ZMK_HOST_OUTPUT_SWITCH)
  zephyr_library()
  # <zmk/ble.h> and <zmk/endpoints.h> live in the ZMK app, not in a module.
  zephyr_library_include_directories(${APPLICATION_SOURCE_DIR}/include)
  zephyr_library_sources(src/host_output_switch.c)
endif()
