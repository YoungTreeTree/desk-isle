idf_component_register(
    SRCS "display/display.c" "transport/stream.c" "transport/protocol.c" "transport/uart_link.c"
         "layout/control.c" "widgets/widget.c" "widgets/widget_paint.c"
         "widgets/mac_load.c" "widgets/codex.c" "widgets/garmin.c" "widgets/bluetooth.c" "widgets/notification.c"
         "pet/pet.c" "pet/pet_scene.c" "../shared/layout.c" "../shared/frosted.c"
         "model3d/scene3d.c" "model3d/model3d.c"
    INCLUDE_DIRS "display" "transport" "layout" "widgets" "pet" "model3d" "../shared/include"
    REQUIRES esp_lcd esp_driver_gpio esp_driver_ledc esp_hw_support esp_timer esp_psram
             esp_driver_jpeg esp_driver_uart esp_tinyusb nvs_flash esp_rom json
)
target_add_binary_data(${COMPONENT_LIB} "${CMAKE_CURRENT_SOURCE_DIR}/../resources/widget_font.bin"
                       BINARY RENAME_TO "widget_font.bin")

include(FetchContent)
if(POLICY CMP0135)
    cmake_policy(SET CMP0135 NEW)
endif()
FetchContent_Declare(desk_lua
    URL https://www.lua.org/ftp/lua-5.4.8.tar.gz
    URL_HASH SHA256=4f18ddae154e793e46eeab727c59ef1c0c0c2b744e7b94219710d76f530629ae)
FetchContent_MakeAvailable(desk_lua)
set(lua_sources lapi lauxlib lbaselib lcode lctype ldebug ldo ldump lfunc lgc
    llex lmathlib lmem lobject lopcodes lparser lstate lstring lstrlib ltable
    ltablib ltm lundump lutf8lib lvm lzio)
list(TRANSFORM lua_sources PREPEND "${desk_lua_SOURCE_DIR}/src/")
list(TRANSFORM lua_sources APPEND ".c")
add_library(desk_lua STATIC ${lua_sources})
target_include_directories(desk_lua PUBLIC "${desk_lua_SOURCE_DIR}/src")
target_compile_options(desk_lua PRIVATE -Os -ffunction-sections -fdata-sections)
target_link_libraries(${COMPONENT_LIB} PRIVATE desk_lua)
