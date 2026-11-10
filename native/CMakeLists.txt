cmake_minimum_required(VERSION 3.10)
project(route_kernels LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release)
endif()

add_library(route_kernels SHARED route_kernels.cpp)

# Keep floating-point results bit-identical to the Dart implementation:
# no fused multiply-add, no fast-math reordering.
if(MSVC)
  target_compile_options(route_kernels PRIVATE /O2 /fp:precise)
else()
  target_compile_options(route_kernels PRIVATE -O2 -ffp-contract=off)
endif()

set_target_properties(route_kernels PROPERTIES
  LIBRARY_OUTPUT_DIRECTORY ${CMAKE_SOURCE_DIR}/../build
  RUNTIME_OUTPUT_DIRECTORY ${CMAKE_SOURCE_DIR}/../build)
