cmake_minimum_required(VERSION 3.28)
project(soda LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

list(APPEND CMAKE_MODULE_PATH "${PROJECT_SOURCE_DIR}/cmake")

include(FetchContent)
include(SodaChez)

set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(LIBUV_BUILD_SHARED OFF CACHE BOOL "" FORCE)
set(LIBUV_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LIBUV_BUILD_BENCH OFF CACHE BOOL "" FORCE)
FetchContent_Declare(
  libuv
  URL https://github.com/libuv/libuv/archive/refs/tags/v1.52.1.tar.gz
  URL_HASH SHA256=478baf2599bfbc882c355288c9cb6f92e0e7dda435fa04031fa5b607cf3f414c
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE
  EXCLUDE_FROM_ALL
)
FetchContent_MakeAvailable(libuv)

set(TREE_SITTER_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(TREE_SITTER_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
FetchContent_Declare(
  tree_sitter
  URL https://github.com/tree-sitter/tree-sitter/archive/refs/tags/v0.26.9.tar.gz
  URL_HASH SHA256=8e14780500933f43d86662fcaa1b0ce99ebe9c220f4680bc929dce09a0e0cfc6
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE
  EXCLUDE_FROM_ALL
)
FetchContent_MakeAvailable(tree_sitter)

FetchContent_Declare(
  tree_sitter_json
  URL https://github.com/tree-sitter/tree-sitter-json/archive/refs/tags/v0.24.8.tar.gz
  URL_HASH SHA256=acf6e8362457e819ed8b613f2ad9a0e1b621a77556c296f3abea58f7880a9213
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE
  EXCLUDE_FROM_ALL
)
FetchContent_MakeAvailable(tree_sitter_json)

find_package(Threads REQUIRED)
find_package(ZLIB REQUIRED)
find_library(SODA_LZ4_LIBRARY NAMES lz4 REQUIRED)
find_library(SODA_TERMINFO_LIBRARY NAMES tinfo terminfo curses REQUIRED)

include(CTest)
if(BUILD_TESTING)
  FetchContent_Declare(
    doctest
    URL https://github.com/doctest/doctest/archive/refs/tags/v2.4.12.tar.gz
    URL_HASH SHA256=73381c7aa4dee704bd935609668cf41880ea7f19fa0504a200e13b74999c2d70
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
    EXCLUDE_FROM_ALL
  )
  FetchContent_MakeAvailable(doctest)
endif()

add_subdirectory(src)

if(BUILD_TESTING)
  add_subdirectory(tests)
endif()

install(TARGETS soda RUNTIME DESTINATION bin)
