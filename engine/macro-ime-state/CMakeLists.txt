cmake_minimum_required(VERSION 3.20)
project(macro-ime-state VERSION 0.1.3 LANGUAGES CXX)

find_package(Fcitx5Core 5.1 REQUIRED)

add_library(macro-ime-state MODULE macro-ime-state.cpp)
target_compile_features(macro-ime-state PRIVATE cxx_std_20)
target_compile_options(macro-ime-state PRIVATE -Wall -Wextra -Wpedantic)
target_link_libraries(macro-ime-state PRIVATE Fcitx5::Core)
set_target_properties(macro-ime-state PROPERTIES
  PREFIX "lib"
  OUTPUT_NAME "macro-ime-state"
)

set(FCITX_VERSION "${Fcitx5Core_VERSION}")
configure_file(macro-ime-state.conf.in macro-ime-state.conf @ONLY)
