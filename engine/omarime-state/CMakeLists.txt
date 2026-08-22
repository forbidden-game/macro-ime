cmake_minimum_required(VERSION 3.20)
project(omarime-state VERSION 0.1.2 LANGUAGES CXX)

find_package(Fcitx5Core 5.1 REQUIRED)

add_library(omarime-state MODULE omarime-state.cpp)
target_compile_features(omarime-state PRIVATE cxx_std_20)
target_compile_options(omarime-state PRIVATE -Wall -Wextra -Wpedantic)
target_link_libraries(omarime-state PRIVATE Fcitx5::Core)
set_target_properties(omarime-state PROPERTIES
  PREFIX "lib"
  OUTPUT_NAME "omarime-state"
)

set(FCITX_VERSION "${Fcitx5Core_VERSION}")
configure_file(omarime-state.conf.in omarime-state.conf @ONLY)
