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
soda_core_test(native_core_tests native_core_tests.cpp soda_native_core)
soda_core_test(runtime_tests runtime/runtime_tests.cpp soda_runtime)
target_link_libraries(runtime_tests PRIVATE soda_document Threads::Threads)

find_program(CHEZ_SCHEME_EXECUTABLE NAMES scheme chezscheme)
find_program(EXPECT_EXECUTABLE NAMES expect)
if(CHEZ_SCHEME_EXECUTABLE)
  add_test(
    NAME scheme_document_tests
    CONFIGURATIONS Debug Release
    COMMAND
      ${CMAKE_COMMAND} -E env
      SODA_DOCUMENT_LIBRARY=$<TARGET_FILE:soda_document>
      ${CHEZ_SCHEME_EXECUTABLE}
      --libdirs ${PROJECT_SOURCE_DIR}/scheme
      --program ${CMAKE_CURRENT_SOURCE_DIR}/scheme/document_tests.ss
  )

  add_test(
    NAME scheme_runtime_tests
    CONFIGURATIONS Debug Release
    COMMAND
      ${CMAKE_COMMAND} -E env
      SODA_RUNTIME_LIBRARY=$<TARGET_FILE:soda_runtime>
      SODA_TEST_FILE=${CMAKE_CURRENT_SOURCE_DIR}/fixtures/ctor_sequence.yaml
      SODA_SAVE_TEST_FILE=${CMAKE_CURRENT_BINARY_DIR}/scheme_runtime_save_test.txt
      ${CHEZ_SCHEME_EXECUTABLE}
      --libdirs ${PROJECT_SOURCE_DIR}/scheme
      --program ${CMAKE_CURRENT_SOURCE_DIR}/scheme/runtime_tests.ss
  )

  add_test(
    NAME scheme_cpp_analysis_tests
    CONFIGURATIONS Debug Release
    COMMAND
      ${CMAKE_COMMAND} -E env
      SODA_DOCUMENT_LIBRARY=$<TARGET_FILE:soda_document>
      SODA_CPP_ANALYSIS_LIBRARY=$<TARGET_FILE:soda_cpp_analysis>
      ${CHEZ_SCHEME_EXECUTABLE}
      --libdirs ${PROJECT_SOURCE_DIR}/scheme
      --program ${CMAKE_CURRENT_SOURCE_DIR}/scheme/cpp_analysis_tests.ss
  )

  add_test(
    NAME scheme_indentation_tests
    CONFIGURATIONS Debug Release
    COMMAND
      ${CMAKE_COMMAND} -E env
      SODA_DOCUMENT_LIBRARY=$<TARGET_FILE:soda_document>
      SODA_CPP_ANALYSIS_LIBRARY=$<TARGET_FILE:soda_cpp_analysis>
      SODA_INDENTATION_LIBRARY=$<TARGET_FILE:soda_indentation>
      ${CHEZ_SCHEME_EXECUTABLE}
      --libdirs ${PROJECT_SOURCE_DIR}/scheme
      --program ${CMAKE_CURRENT_SOURCE_DIR}/scheme/indentation_tests.ss
  )

  add_test(
    NAME scheme_buffer_tests
    CONFIGURATIONS Debug Release
    COMMAND
      ${CMAKE_COMMAND} -E env
      SODA_DOCUMENT_LIBRARY=$<TARGET_FILE:soda_document>
      ${CHEZ_SCHEME_EXECUTABLE}
      --libdirs ${PROJECT_SOURCE_DIR}/scheme
      --program ${CMAKE_CURRENT_SOURCE_DIR}/scheme/buffer_tests.ss
  )

  add_test(
    NAME scheme_input_tests
    CONFIGURATIONS Debug Release
    COMMAND
      ${CHEZ_SCHEME_EXECUTABLE}
      --libdirs ${PROJECT_SOURCE_DIR}/scheme
      --program ${CMAKE_CURRENT_SOURCE_DIR}/scheme/input_tests.ss
  )

  add_test(
    NAME scheme_fuzzy_tests
    CONFIGURATIONS Debug Release
    COMMAND
      ${CHEZ_SCHEME_EXECUTABLE}
      --libdirs ${PROJECT_SOURCE_DIR}/scheme
      --program ${CMAKE_CURRENT_SOURCE_DIR}/scheme/fuzzy_tests.ss
  )

  add_test(
    NAME scheme_editor_tests
    CONFIGURATIONS Debug Release
    COMMAND
      ${CMAKE_COMMAND} -E env
      SODA_DOCUMENT_LIBRARY=$<TARGET_FILE:soda_document>
      SODA_CPP_ANALYSIS_LIBRARY=$<TARGET_FILE:soda_cpp_analysis>
      SODA_INDENTATION_LIBRARY=$<TARGET_FILE:soda_indentation>
      ${CHEZ_SCHEME_EXECUTABLE}
      --libdirs ${PROJECT_SOURCE_DIR}/scheme
      --program ${CMAKE_CURRENT_SOURCE_DIR}/scheme/editor_tests.ss
  )

  add_test(
    NAME scheme_repl_tests
    CONFIGURATIONS Debug Release
    COMMAND
      ${CMAKE_COMMAND} -E env
      SODA_DOCUMENT_LIBRARY=$<TARGET_FILE:soda_document>
      SODA_CPP_ANALYSIS_LIBRARY=$<TARGET_FILE:soda_cpp_analysis>
      SODA_INDENTATION_LIBRARY=$<TARGET_FILE:soda_indentation>
      ${CHEZ_SCHEME_EXECUTABLE}
      --libdirs ${PROJECT_SOURCE_DIR}/scheme
      --program ${CMAKE_CURRENT_SOURCE_DIR}/scheme/repl_tests.ss
  )

  add_test(
    NAME scheme_semantics_tests
    CONFIGURATIONS Debug Release
    COMMAND
      ${CMAKE_COMMAND} -E env
      SODA_DOCUMENT_LIBRARY=$<TARGET_FILE:soda_document>
      ${CHEZ_SCHEME_EXECUTABLE}
      --libdirs ${PROJECT_SOURCE_DIR}/scheme
      --program ${CMAKE_CURRENT_SOURCE_DIR}/scheme/scheme_semantics_tests.ss
  )

  add_test(
    NAME scheme_file_tests
    CONFIGURATIONS Debug Release
    COMMAND
      ${CMAKE_COMMAND} -E env
      SODA_DOCUMENT_LIBRARY=$<TARGET_FILE:soda_document>
      SODA_CPP_ANALYSIS_LIBRARY=$<TARGET_FILE:soda_cpp_analysis>
      SODA_INDENTATION_LIBRARY=$<TARGET_FILE:soda_indentation>
      SODA_RUNTIME_LIBRARY=$<TARGET_FILE:soda_runtime>
      SODA_EDITOR_OPEN_TEST_FILE=${CMAKE_CURRENT_SOURCE_DIR}/scheme/file_tests.ss
      SODA_EDITOR_SAVE_AS_TEST_FILE=${CMAKE_CURRENT_BINARY_DIR}/scheme_editor_save_as_test.txt
      SODA_EDITOR_SAVE_TEST_FILE=${CMAKE_CURRENT_BINARY_DIR}/scheme_editor_save_test.txt
      ${CHEZ_SCHEME_EXECUTABLE}
      --libdirs ${PROJECT_SOURCE_DIR}/scheme
      --program ${CMAKE_CURRENT_SOURCE_DIR}/scheme/file_tests.ss
  )

  if(EXPECT_EXECUTABLE)
    add_test(
      NAME tui_smoke_tests
      CONFIGURATIONS Debug Release
      COMMAND
        ${CMAKE_COMMAND} -E env
        SODA_BUILD_CONFIGURATION=$<CONFIG>
        CHEZ_SCHEME=${CHEZ_SCHEME_EXECUTABLE}
        ${EXPECT_EXECUTABLE}
        ${CMAKE_CURRENT_SOURCE_DIR}/tui_smoke.exp
        ${PROJECT_SOURCE_DIR}/bin/soda
        ${CMAKE_CURRENT_SOURCE_DIR}/fixtures/ctor_sequence.yaml
    )
  endif()
endif()
