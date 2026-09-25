cmake_minimum_required(VERSION 3.22.1)
project(richpresence_bridge CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Discord's Social SDK (not in the repo; see android/sdk/README.md)
add_library(discord_partner_sdk SHARED IMPORTED)
set_target_properties(discord_partner_sdk PROPERTIES
    IMPORTED_LOCATION ${SDK_DIR}/jni/${ANDROID_ABI}/libdiscord_partner_sdk.so)

add_library(richpresence_bridge SHARED bridge.cpp)
target_include_directories(richpresence_bridge PRIVATE ${SDK_DIR}/include)
target_link_libraries(richpresence_bridge discord_partner_sdk log)
# newer phones use 16 KB memory pages
target_link_options(richpresence_bridge PRIVATE "-Wl,-z,max-page-size=16384")
