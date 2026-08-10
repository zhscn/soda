function(soda_core_test target source library)
  add_executable(${target} ${source})
  target_link_libraries(${target} PRIVATE ${library} doctest::doctest)
  add_test(NAME ${target} COMMAND ${target})
endfunction()

soda_core_test(document_tests document/document_tests.cpp soda_document)
soda_core_test(text_tests document/text_tests.cpp soda_document)
soda_core_test(document_abi_tests document/c_api_tests.cpp soda_document)

soda_core_test(lexer_tests lexer/lexer_tests.cpp soda_cpp_lexer)
soda_core_test(relex_tests lexer/relex_tests.cpp soda_cpp_lexer)
soda_core_test(token_buffer_tests lexer/token_buffer_tests.cpp soda_cpp_lexer)

soda_core_test(green_tree_tests syntax/green_tree_tests.cpp soda_cpp_analysis)
soda_core_test(parser_tests syntax/parser_tests.cpp soda_cpp_analysis)
soda_core_test(reparse_tests syntax/reparse_tests.cpp soda_cpp_analysis)
soda_core_test(structure_tests syntax/structure_tests.cpp soda_cpp_analysis)
soda_core_test(cpp_analysis_abi_tests syntax/c_api_tests.cpp soda_cpp_analysis)

add_executable(syntax_concurrency_tests syntax/concurrency_tests.cpp)
target_link_libraries(syntax_concurrency_tests
  PRIVATE soda_cpp_analysis doctest::doctest Threads::Threads
)
add_test(NAME syntax_concurrency_tests COMMAND syntax_concurrency_tests)

soda_core_test(clang_format_style_tests
  formatting/clang_format_style_tests.cpp
  soda_indentation
)
soda_core_test(indentation_tests indentation/indentation_tests.cpp soda_indentation)
soda_core_test(indentation_abi_tests indentation/c_api_tests.cpp soda_indentation)
soda_core_test(native_substrate_tests native_substrate_tests.cpp soda_native_substrate)
soda_core_test(runtime_tests runtime/runtime_tests.cpp soda_runtime)
target_link_libraries(runtime_tests PRIVATE Threads::Threads)

file(GLOB_RECURSE SODA_TEST_SCHEME_SOURCES
  CONFIGURE_DEPENDS
  "${PROJECT_SOURCE_DIR}/scheme/*.sls"
  "${PROJECT_SOURCE_DIR}/scheme/*.ss"
)

file(GLOB_RECURSE SODA_TEST_SUPPORT_SCHEME_SOURCES
  CONFIGURE_DEPENDS
  "${CMAKE_CURRENT_SOURCE_DIR}/scheme/soda/*.sls"
  "${CMAKE_CURRENT_SOURCE_DIR}/scheme/soda/*.ss"
)

add_executable(scheme_kernel_tests
  "${PROJECT_SOURCE_DIR}/src/launcher/main.c"
)
target_include_directories(scheme_kernel_tests PRIVATE
  "${PROJECT_SOURCE_DIR}/src"
  "${PROJECT_BINARY_DIR}/src/generated"
  "${SODA_CHEZ_INCLUDE_DIR}"
)
target_link_libraries(scheme_kernel_tests PRIVATE
  soda_native_substrate
  "${SODA_CHEZ_KERNEL_LIBRARY}"
  ZLIB::ZLIB
  "${SODA_LZ4_LIBRARY}"
  "${SODA_TERMINFO_LIBRARY}"
  Threads::Threads
  "${CMAKE_DL_LIBS}"
  m
)
set_target_properties(scheme_kernel_tests PROPERTIES LINKER_LANGUAGE CXX)
soda_target_warnings(scheme_kernel_tests)
soda_embed_chez_application(scheme_kernel_tests
  SOURCE_DIR "${PROJECT_SOURCE_DIR}/scheme"
  PROGRAM "soda/test/kernel-tests.ss"
  PROGRAM_SOURCE "${CMAKE_CURRENT_SOURCE_DIR}/scheme/kernel_tests.ss"
  SOURCES
    ${SODA_TEST_SCHEME_SOURCES}
    ${SODA_TEST_SUPPORT_SCHEME_SOURCES}
  EXTRA_SOURCE_DIRS "${CMAKE_CURRENT_SOURCE_DIR}/scheme"
)
add_test(NAME scheme_kernel_tests COMMAND scheme_kernel_tests)
set_tests_properties(scheme_kernel_tests PROPERTIES
  ENVIRONMENT
    "LSAN_OPTIONS=suppressions=${CMAKE_CURRENT_SOURCE_DIR}/lsan.supp;SODA_RECOVERY_DIRECTORY=${CMAKE_CURRENT_BINARY_DIR}/scheme-recovery"
)
