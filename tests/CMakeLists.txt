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
  set(SODA_SCHEME_NATIVE_LIBRARY
    $<TARGET_FILE:soda_scheme_native_test>
  )

  add_test(
    NAME scheme_document_tests
    CONFIGURATIONS Debug Release
    COMMAND
      ${CMAKE_COMMAND} -E env
      SODA_DOCUMENT_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      ${CHEZ_SCHEME_EXECUTABLE}
      --libdirs ${PROJECT_SOURCE_DIR}/scheme
      --program ${CMAKE_CURRENT_SOURCE_DIR}/scheme/document_tests.ss
  )

  add_test(
    NAME scheme_runtime_tests
    CONFIGURATIONS Debug Release
    COMMAND
      ${CMAKE_COMMAND} -E env
      SODA_RUNTIME_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
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
      SODA_DOCUMENT_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      SODA_CPP_ANALYSIS_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      ${CHEZ_SCHEME_EXECUTABLE}
      --libdirs ${PROJECT_SOURCE_DIR}/scheme
      --program ${CMAKE_CURRENT_SOURCE_DIR}/scheme/cpp_analysis_tests.ss
  )

  add_test(
    NAME scheme_tree_sitter_tests
    CONFIGURATIONS Debug Release
    COMMAND
      ${CMAKE_COMMAND} -E env
      SODA_DOCUMENT_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      SODA_TREE_SITTER_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      SODA_RUNTIME=$<TARGET_FILE_DIR:soda>/runtime
      ${CHEZ_SCHEME_EXECUTABLE}
      --libdirs ${PROJECT_SOURCE_DIR}/scheme
      --program ${CMAKE_CURRENT_SOURCE_DIR}/scheme/tree_sitter_tests.ss
  )

  add_test(
    NAME scheme_indentation_tests
    CONFIGURATIONS Debug Release
    COMMAND
      ${CMAKE_COMMAND} -E env
      SODA_DOCUMENT_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      SODA_CPP_ANALYSIS_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      SODA_INDENTATION_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      ${CHEZ_SCHEME_EXECUTABLE}
      --libdirs ${PROJECT_SOURCE_DIR}/scheme
      --program ${CMAKE_CURRENT_SOURCE_DIR}/scheme/indentation_tests.ss
  )

  add_test(
    NAME scheme_buffer_tests
    CONFIGURATIONS Debug Release
    COMMAND
      ${CMAKE_COMMAND} -E env
      SODA_DOCUMENT_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      SODA_RUNTIME_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      ${CHEZ_SCHEME_EXECUTABLE}
      --libdirs ${PROJECT_SOURCE_DIR}/scheme
      --program ${CMAKE_CURRENT_SOURCE_DIR}/scheme/buffer_tests.ss
  )

  add_test(
    NAME scheme_core_tests
    CONFIGURATIONS Debug Release
    COMMAND
      ${CMAKE_COMMAND} -E env
      SODA_DOCUMENT_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      ${CHEZ_SCHEME_EXECUTABLE}
      --libdirs ${PROJECT_SOURCE_DIR}/scheme
      --program ${CMAKE_CURRENT_SOURCE_DIR}/scheme/core_tests.ss
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
    NAME scheme_json_tests
    CONFIGURATIONS Debug Release
    COMMAND
      ${CHEZ_SCHEME_EXECUTABLE}
      --libdirs ${PROJECT_SOURCE_DIR}/scheme
      --program ${CMAKE_CURRENT_SOURCE_DIR}/scheme/json_tests.ss
  )

  add_test(
    NAME scheme_lsp_json_rpc_tests
    CONFIGURATIONS Debug Release
    COMMAND
      ${CHEZ_SCHEME_EXECUTABLE}
      --libdirs ${PROJECT_SOURCE_DIR}/scheme
      --program ${CMAKE_CURRENT_SOURCE_DIR}/scheme/lsp_json_rpc_tests.ss
  )

  add_test(
    NAME scheme_lsp_protocol_tests
    CONFIGURATIONS Debug Release
    COMMAND
      ${CHEZ_SCHEME_EXECUTABLE}
      --libdirs ${PROJECT_SOURCE_DIR}/scheme
      --program ${CMAKE_CURRENT_SOURCE_DIR}/scheme/lsp_protocol_tests.ss
  )

  add_test(
    NAME scheme_lsp_client_tests
    CONFIGURATIONS Debug Release
    COMMAND
      ${CMAKE_COMMAND} -E env
      SODA_DOCUMENT_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      SODA_RUNTIME_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      ${CHEZ_SCHEME_EXECUTABLE}
      --libdirs ${PROJECT_SOURCE_DIR}/scheme
      --program ${CMAKE_CURRENT_SOURCE_DIR}/scheme/lsp_client_tests.ss
  )

  add_test(
    NAME scheme_lsp_position_tests
    CONFIGURATIONS Debug Release
    COMMAND
      ${CMAKE_COMMAND} -E env
      SODA_DOCUMENT_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      ${CHEZ_SCHEME_EXECUTABLE}
      --libdirs ${PROJECT_SOURCE_DIR}/scheme
      --program ${CMAKE_CURRENT_SOURCE_DIR}/scheme/lsp_position_tests.ss
  )

  add_test(
    NAME scheme_regexp_tests
    CONFIGURATIONS Debug Release
    COMMAND
      ${CHEZ_SCHEME_EXECUTABLE}
      --libdirs ${PROJECT_SOURCE_DIR}/scheme
      --program ${CMAKE_CURRENT_SOURCE_DIR}/scheme/regexp_tests.ss
  )

  add_test(
    NAME scheme_project_tests
    CONFIGURATIONS Debug Release
    COMMAND
      ${CHEZ_SCHEME_EXECUTABLE}
      --libdirs ${PROJECT_SOURCE_DIR}/scheme
      --program ${CMAKE_CURRENT_SOURCE_DIR}/scheme/project_tests.ss
  )

  add_test(
    NAME scheme_project_resource_tests
    CONFIGURATIONS Debug Release
    COMMAND
      ${CMAKE_COMMAND} -E env
      SODA_DOCUMENT_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      SODA_RUNTIME_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      SODA_PROJECT_RESOURCE_FIXTURE=${CMAKE_CURRENT_SOURCE_DIR}/fixtures/project_resource
      ${CHEZ_SCHEME_EXECUTABLE}
      --libdirs ${PROJECT_SOURCE_DIR}/scheme
      --program ${CMAKE_CURRENT_SOURCE_DIR}/scheme/project_resource_tests.ss
  )

  add_test(
    NAME scheme_project_workspace_tests
    CONFIGURATIONS Debug Release
    COMMAND
      ${CMAKE_COMMAND} -E env
      SODA_DOCUMENT_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      ${CHEZ_SCHEME_EXECUTABLE}
      --libdirs ${PROJECT_SOURCE_DIR}/scheme
      --program ${CMAKE_CURRENT_SOURCE_DIR}/scheme/project_workspace_tests.ss
  )

  add_test(
    NAME scheme_workbench_tests
    CONFIGURATIONS Debug Release
    COMMAND
      ${CMAKE_COMMAND} -E env
      SODA_DOCUMENT_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      ${CHEZ_SCHEME_EXECUTABLE}
      --libdirs ${PROJECT_SOURCE_DIR}/scheme
      --program ${CMAKE_CURRENT_SOURCE_DIR}/scheme/workbench_tests.ss
  )

  add_test(
    NAME scheme_workbench_session_tests
    CONFIGURATIONS Debug Release
    COMMAND
      ${CMAKE_COMMAND} -E env
      SODA_DOCUMENT_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      ${CHEZ_SCHEME_EXECUTABLE}
      --libdirs ${PROJECT_SOURCE_DIR}/scheme
      --program ${CMAKE_CURRENT_SOURCE_DIR}/scheme/workbench_session_tests.ss
  )

  add_test(
    NAME scheme_tui_application_tests
    CONFIGURATIONS Debug Release
    COMMAND
      ${CMAKE_COMMAND} -E env
      SODA_DOCUMENT_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      SODA_RUNTIME_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      ${CHEZ_SCHEME_EXECUTABLE}
      --libdirs ${PROJECT_SOURCE_DIR}/scheme
      --program ${CMAKE_CURRENT_SOURCE_DIR}/scheme/tui_application_tests.ss
  )

  add_test(
    NAME scheme_tui_application_view_tests
    CONFIGURATIONS Debug Release
    COMMAND
      ${CMAKE_COMMAND} -E env
      SODA_DOCUMENT_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      ${CHEZ_SCHEME_EXECUTABLE}
      --libdirs ${PROJECT_SOURCE_DIR}/scheme
      --program ${CMAKE_CURRENT_SOURCE_DIR}/scheme/tui_application_view_tests.ss
  )

  add_test(
    NAME scheme_dashboard_tests
    CONFIGURATIONS Debug Release
    COMMAND
      ${CMAKE_COMMAND} -E env
      SODA_DOCUMENT_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      SODA_DASHBOARD_PROJECT_FIXTURE=${CMAKE_CURRENT_SOURCE_DIR}/fixtures/project_resource
      ${CHEZ_SCHEME_EXECUTABLE}
      --libdirs ${PROJECT_SOURCE_DIR}/scheme
      --program ${CMAKE_CURRENT_SOURCE_DIR}/scheme/dashboard_tests.ss
  )

  add_test(
    NAME scheme_tui_examples_tests
    CONFIGURATIONS Debug Release
    COMMAND
      ${CMAKE_COMMAND} -E env
      SODA_DOCUMENT_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      ${CHEZ_SCHEME_EXECUTABLE}
      --libdirs ${PROJECT_SOURCE_DIR}/scheme
      --program ${CMAKE_CURRENT_SOURCE_DIR}/scheme/tui_examples_tests.ss
  )

  add_test(
    NAME scheme_language_session_tests
    CONFIGURATIONS Debug Release
    COMMAND
      ${CMAKE_COMMAND} -E env
      SODA_DOCUMENT_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      ${CHEZ_SCHEME_EXECUTABLE}
      --libdirs ${PROJECT_SOURCE_DIR}/scheme
      --program ${CMAKE_CURRENT_SOURCE_DIR}/scheme/language_session_tests.ss
  )

  add_test(
    NAME scheme_editor_tests
    CONFIGURATIONS Debug Release
    COMMAND
      ${CMAKE_COMMAND} -E env
      SODA_DOCUMENT_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      SODA_CPP_ANALYSIS_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      SODA_INDENTATION_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      SODA_RUNTIME=$<TARGET_FILE_DIR:soda>/runtime
      SODA_TEST_INIT_FILE=${CMAKE_CURRENT_SOURCE_DIR}/fixtures/editor_init.ss
      SODA_TEST_INIT_V2_FILE=${CMAKE_CURRENT_SOURCE_DIR}/fixtures/editor_init_v2.ss
      SODA_TEST_INIT_FAILING_FILE=${CMAKE_CURRENT_SOURCE_DIR}/fixtures/editor_init_failing.ss
      ${CHEZ_SCHEME_EXECUTABLE}
      --libdirs ${PROJECT_SOURCE_DIR}/scheme
      --program ${CMAKE_CURRENT_SOURCE_DIR}/scheme/editor_tests.ss
  )

  add_test(
    NAME scheme_repl_tests
    CONFIGURATIONS Debug Release
    COMMAND
      ${CMAKE_COMMAND} -E env
      SODA_DOCUMENT_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      SODA_CPP_ANALYSIS_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      SODA_INDENTATION_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      ${CHEZ_SCHEME_EXECUTABLE}
      --libdirs ${PROJECT_SOURCE_DIR}/scheme
      --program ${CMAKE_CURRENT_SOURCE_DIR}/scheme/repl_tests.ss
  )

  add_test(
    NAME scheme_inspector_tests
    CONFIGURATIONS Debug Release
    COMMAND
      ${CHEZ_SCHEME_EXECUTABLE}
      --libdirs ${PROJECT_SOURCE_DIR}/scheme
      --program ${CMAKE_CURRENT_SOURCE_DIR}/scheme/inspector_tests.ss
  )

  add_test(
    NAME scheme_evaluation_runtime_tests
    CONFIGURATIONS Debug Release
    COMMAND
      ${CMAKE_COMMAND} -E env
      SODA_DOCUMENT_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      SODA_CPP_ANALYSIS_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      SODA_INDENTATION_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      SODA_RUNTIME_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      SODA_SOURCE_DEBUG_LOADED_FILE=${CMAKE_CURRENT_SOURCE_DIR}/fixtures/source_debug_loaded.ss
      ${CHEZ_SCHEME_EXECUTABLE}
      --libdirs ${PROJECT_SOURCE_DIR}/scheme
      --program ${CMAKE_CURRENT_SOURCE_DIR}/scheme/evaluation_runtime_tests.ss
  )

  add_test(
    NAME scheme_process_comint_tests
    CONFIGURATIONS Debug Release
    COMMAND
      ${CMAKE_COMMAND} -E env
      SODA_DOCUMENT_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      SODA_CPP_ANALYSIS_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      SODA_INDENTATION_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      SODA_RUNTIME_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      ${CHEZ_SCHEME_EXECUTABLE}
      --libdirs ${PROJECT_SOURCE_DIR}/scheme
      --program ${CMAKE_CURRENT_SOURCE_DIR}/scheme/process_comint_tests.ss
  )

  add_test(
    NAME scheme_managed_process_tests
    CONFIGURATIONS Debug Release
    COMMAND
      ${CMAKE_COMMAND} -E env
      SODA_RUNTIME_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      ${CHEZ_SCHEME_EXECUTABLE}
      --libdirs ${PROJECT_SOURCE_DIR}/scheme
      --program ${CMAKE_CURRENT_SOURCE_DIR}/scheme/managed_process_tests.ss
  )

  add_test(
    NAME scheme_semantics_tests
    CONFIGURATIONS Debug Release
    COMMAND
      ${CMAKE_COMMAND} -E env
      SODA_DOCUMENT_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      ${CHEZ_SCHEME_EXECUTABLE}
      --libdirs ${PROJECT_SOURCE_DIR}/scheme
      --program ${CMAKE_CURRENT_SOURCE_DIR}/scheme/scheme_semantics_tests.ss
  )

  set(SODA_SCHEME_API_CACHE_TEST_ROOT
    "${CMAKE_CURRENT_BINARY_DIR}/scheme_api_index_cache_test"
  )
  file(MAKE_DIRECTORY "${SODA_SCHEME_API_CACHE_TEST_ROOT}/sources")
  add_test(
    NAME scheme_api_index_cache_tests
    CONFIGURATIONS Debug Release
    COMMAND
      ${CMAKE_COMMAND} -E env
      SODA_SCHEME_API_CACHE_TEST_ROOT=${SODA_SCHEME_API_CACHE_TEST_ROOT}
      SODA_SCHEME_SOURCE_ROOT=${PROJECT_SOURCE_DIR}/scheme
      ${CHEZ_SCHEME_EXECUTABLE}
      --libdirs ${PROJECT_SOURCE_DIR}/scheme
      --program ${CMAKE_CURRENT_SOURCE_DIR}/scheme/scheme_api_index_cache_tests.ss
  )

  add_test(
    NAME scheme_file_tests
    CONFIGURATIONS Debug Release
    COMMAND
      ${CMAKE_COMMAND} -E env
      SODA_DOCUMENT_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      SODA_CPP_ANALYSIS_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      SODA_INDENTATION_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      SODA_RUNTIME_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      SODA_EDITOR_OPEN_TEST_FILE=${CMAKE_CURRENT_SOURCE_DIR}/scheme/file_tests.ss
      SODA_EDITOR_SAVE_AS_TEST_FILE=${CMAKE_CURRENT_BINARY_DIR}/scheme_editor_save_as_test.txt
      SODA_EDITOR_SAVE_TEST_FILE=${CMAKE_CURRENT_BINARY_DIR}/scheme_editor_save_test.txt
      ${CHEZ_SCHEME_EXECUTABLE}
      --libdirs ${PROJECT_SOURCE_DIR}/scheme
      --program ${CMAKE_CURRENT_SOURCE_DIR}/scheme/file_tests.ss
  )

  add_test(
    NAME scheme_project_session_tests
    CONFIGURATIONS Debug Release
    COMMAND
      ${CMAKE_COMMAND} -E env
      SODA_DOCUMENT_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      SODA_CPP_ANALYSIS_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      SODA_INDENTATION_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      SODA_RUNTIME_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      SODA_SCHEME_PROJECT_TEST_ROOT=${CMAKE_CURRENT_SOURCE_DIR}/fixtures/scheme_project
      ${CHEZ_SCHEME_EXECUTABLE}
      --libdirs ${PROJECT_SOURCE_DIR}/scheme
      --program ${CMAKE_CURRENT_SOURCE_DIR}/scheme/scheme_project_session_tests.ss
  )

  add_test(
    NAME scheme_environment_tests
    CONFIGURATIONS Debug Release
    COMMAND
      ${CMAKE_COMMAND} -E env
      SODA_DOCUMENT_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      SODA_CPP_ANALYSIS_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      SODA_INDENTATION_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      SODA_RUNTIME_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      ${CHEZ_SCHEME_EXECUTABLE}
      --libdirs ${PROJECT_SOURCE_DIR}/scheme
      --program ${CMAKE_CURRENT_SOURCE_DIR}/scheme/scheme_environment_tests.ss
  )

  set(SODA_SCHEME_INTERFACE_BUILD_OBJECT
    "${CMAKE_CURRENT_BINARY_DIR}/scheme_interface_build"
  )
  file(MAKE_DIRECTORY
    "${SODA_SCHEME_INTERFACE_BUILD_OBJECT}/fixture/scheme-interface-build"
  )
  add_test(
    NAME scheme_interface_build_tests
    CONFIGURATIONS Debug Release
    COMMAND
      ${CMAKE_COMMAND} -E env
      SODA_SCHEME_INTERFACE_BUILD_SOURCE=${CMAKE_CURRENT_SOURCE_DIR}/fixtures/scheme_interface_build
      SODA_SCHEME_INTERFACE_BUILD_OBJECT=${SODA_SCHEME_INTERFACE_BUILD_OBJECT}
      ${CHEZ_SCHEME_EXECUTABLE}
      --libdirs ${PROJECT_SOURCE_DIR}/scheme
      --program ${CMAKE_CURRENT_SOURCE_DIR}/scheme/scheme_interface_build_tests.ss
  )

  add_test(
    NAME scheme_rename_tests
    CONFIGURATIONS Debug Release
    COMMAND
      ${CMAKE_COMMAND} -E env
      SODA_DOCUMENT_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      SODA_CPP_ANALYSIS_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      SODA_INDENTATION_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      SODA_RUNTIME_LIBRARY=${SODA_SCHEME_NATIVE_LIBRARY}
      ${CHEZ_SCHEME_EXECUTABLE}
      --libdirs ${PROJECT_SOURCE_DIR}/scheme
      --program ${CMAKE_CURRENT_SOURCE_DIR}/scheme/scheme_rename_tests.ss
  )

  if(EXPECT_EXECUTABLE)
    add_test(
      NAME tui_smoke_tests
      CONFIGURATIONS Debug Release
      COMMAND
        ${CMAKE_COMMAND} -E env
        SODA_INIT_FILE=
        ${EXPECT_EXECUTABLE}
        ${CMAKE_CURRENT_SOURCE_DIR}/tui_smoke.exp
        $<TARGET_FILE:soda>
        ${CMAKE_CURRENT_SOURCE_DIR}/fixtures/ctor_sequence.yaml
    )
  endif()
endif()
