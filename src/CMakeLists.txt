function(soda_target_warnings target)
  target_compile_options(${target} PRIVATE
    -Wall
    -Wextra
    -Wconversion
    -Wshadow
  )
endfunction()

add_library(soda_document STATIC
  document/c_api.cpp
  document/document.cpp
  document/line_index.cpp
  document/text.cpp
)
target_include_directories(soda_document PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_features(soda_document PUBLIC cxx_std_23)
set_target_properties(soda_document PROPERTIES POSITION_INDEPENDENT_CODE ON)
soda_target_warnings(soda_document)

add_library(soda_cpp_lexer STATIC
  cpp_lexer/lexer.cpp
  cpp_lexer/token_buffer.cpp
)
target_link_libraries(soda_cpp_lexer PUBLIC soda_document)
set_target_properties(soda_cpp_lexer PROPERTIES POSITION_INDEPENDENT_CODE ON)
soda_target_warnings(soda_cpp_lexer)

add_library(soda_cpp_analysis STATIC
  syntax/c_api.cpp
  syntax/analysis.cpp
  syntax/green_node.cpp
  syntax/highlighting.cpp
  syntax/parser.cpp
  syntax/structure.cpp
  syntax/syntax_tree.cpp
)
target_link_libraries(soda_cpp_analysis PUBLIC soda_cpp_lexer)
set_target_properties(soda_cpp_analysis PROPERTIES POSITION_INDEPENDENT_CODE ON)
soda_target_warnings(soda_cpp_analysis)

add_library(soda_indentation STATIC
  commands/editor_commands.cpp
  formatting/clang_format_style.cpp
  indentation/c_api.cpp
  indentation/expression_continuation.cpp
  indentation/indentation_service.cpp
)
target_link_libraries(soda_indentation PUBLIC soda_cpp_analysis)
set_target_properties(soda_indentation PROPERTIES POSITION_INDEPENDENT_CODE ON)
soda_target_warnings(soda_indentation)

add_library(soda_runtime STATIC
  runtime/c_api.cpp
  runtime/runtime.cpp
  runtime/terminal_c_api.cpp
)
target_include_directories(soda_runtime PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_features(soda_runtime PUBLIC cxx_std_23)
target_link_libraries(soda_runtime PUBLIC uv_a)
set_target_properties(soda_runtime PROPERTIES POSITION_INDEPENDENT_CODE ON)
soda_target_warnings(soda_runtime)

add_library(soda_native_core INTERFACE)
target_link_libraries(soda_native_core INTERFACE
  soda_document
  soda_cpp_analysis
  soda_indentation
  soda_runtime
)

file(GLOB_RECURSE SODA_SCHEME_SOURCES
  CONFIGURE_DEPENDS
  "${PROJECT_SOURCE_DIR}/scheme/*.sls"
  "${PROJECT_SOURCE_DIR}/scheme/*.ss"
)

set(SODA_ABI_HEADERS
  "${CMAKE_CURRENT_SOURCE_DIR}/document/c_api.h"
  "${CMAKE_CURRENT_SOURCE_DIR}/syntax/c_api.h"
  "${CMAKE_CURRENT_SOURCE_DIR}/indentation/c_api.h"
  "${CMAKE_CURRENT_SOURCE_DIR}/runtime/c_api.h"
)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
  ${SODA_SCHEME_SOURCES}
  ${SODA_ABI_HEADERS}
)

set(soda_foreign_symbols)
foreach(abi_header IN LISTS SODA_ABI_HEADERS)
  file(READ "${abi_header}" abi_contents)
  string(REGEX MATCHALL
    "soda_[A-Za-z0-9_]+[ \t\r\n]*\\("
    header_foreign_symbols
    "${abi_contents}"
  )
  foreach(symbol_with_parenthesis IN LISTS header_foreign_symbols)
    string(REGEX REPLACE
      "[ \t\r\n]*\\($"
      ""
      symbol
      "${symbol_with_parenthesis}"
    )
    list(APPEND soda_foreign_symbols "${symbol}")
  endforeach()
endforeach()
list(REMOVE_DUPLICATES soda_foreign_symbols)
list(SORT soda_foreign_symbols)

set(soda_foreign_symbol_declarations)
foreach(symbol IN LISTS soda_foreign_symbols)
  string(APPEND soda_foreign_symbol_declarations
    "SODA_FOREIGN_SYMBOL(${symbol})\n"
  )
endforeach()

set(soda_generated_dir "${CMAKE_CURRENT_BINARY_DIR}/generated")
file(MAKE_DIRECTORY "${soda_generated_dir}")
file(CONFIGURE
  OUTPUT "${soda_generated_dir}/soda_foreign_symbols.inc"
  CONTENT "${soda_foreign_symbol_declarations}"
)

add_executable(soda launcher/main.c)
target_include_directories(soda PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${soda_generated_dir}"
  "${SODA_CHEZ_INCLUDE_DIR}"
)
target_link_libraries(soda PRIVATE
  soda_native_core
  "${SODA_CHEZ_KERNEL_LIBRARY}"
  ZLIB::ZLIB
  "${SODA_LZ4_LIBRARY}"
  "${SODA_TERMINFO_LIBRARY}"
  Threads::Threads
  "${CMAKE_DL_LIBS}"
  m
)
set_target_properties(soda PROPERTIES LINKER_LANGUAGE CXX)
soda_target_warnings(soda)
soda_embed_chez_application(soda
  SOURCE_DIR "${PROJECT_SOURCE_DIR}/scheme"
  PROGRAM "soda/editor/main.ss"
  SOURCES ${SODA_SCHEME_SOURCES}
)

if(BUILD_TESTING)
  add_test(
    NAME scheme_embedded_api_index_tests
    CONFIGURATIONS Debug Release
    COMMAND
      "${SODA_CHEZ_SCHEME_EXECUTABLE}"
      --libdirs
      "${CMAKE_CURRENT_BINARY_DIR}/generated/chez/scheme"
      --program
      "${PROJECT_SOURCE_DIR}/tests/scheme/embedded_api_index_tests.ss"
  )
endif()

if(BUILD_TESTING)
  add_library(soda_scheme_native_test SHARED
    document/c_api.cpp
    document/document.cpp
    document/line_index.cpp
    document/text.cpp
    cpp_lexer/lexer.cpp
    cpp_lexer/token_buffer.cpp
    syntax/c_api.cpp
    syntax/analysis.cpp
    syntax/green_node.cpp
    syntax/highlighting.cpp
    syntax/parser.cpp
    syntax/structure.cpp
    syntax/syntax_tree.cpp
    commands/editor_commands.cpp
    formatting/clang_format_style.cpp
    indentation/c_api.cpp
    indentation/expression_continuation.cpp
    indentation/indentation_service.cpp
    runtime/c_api.cpp
    runtime/runtime.cpp
    runtime/terminal_c_api.cpp
  )
  target_include_directories(soda_scheme_native_test
    PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}"
  )
  target_compile_features(soda_scheme_native_test PUBLIC cxx_std_23)
  target_link_libraries(soda_scheme_native_test PRIVATE uv_a)
  soda_target_warnings(soda_scheme_native_test)
endif()
