add_library(soda_document SHARED
  document/c_api.cpp
  document/document.cpp
  document/line_index.cpp
  document/text.cpp
)
target_include_directories(soda_document PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_definitions(soda_document PRIVATE SODA_DOCUMENT_BUILD)
target_compile_features(soda_document PUBLIC cxx_std_23)

add_library(soda_cpp_lexer STATIC
  cpp_lexer/lexer.cpp
  cpp_lexer/token_buffer.cpp
)
target_link_libraries(soda_cpp_lexer PUBLIC soda_document)

add_library(soda_cpp_analysis STATIC
  syntax/analysis.cpp
  syntax/green_node.cpp
  syntax/parser.cpp
  syntax/structure.cpp
  syntax/syntax_tree.cpp
)
target_link_libraries(soda_cpp_analysis PUBLIC soda_cpp_lexer)

add_library(soda_indentation STATIC
  commands/editor_commands.cpp
  formatting/clang_format_style.cpp
  indentation/expression_continuation.cpp
  indentation/indentation_service.cpp
)
target_link_libraries(soda_indentation PUBLIC soda_cpp_analysis)

add_library(soda_runtime SHARED
  runtime/c_api.cpp
  runtime/runtime.cpp
)
target_include_directories(soda_runtime PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_definitions(soda_runtime PRIVATE SODA_RUNTIME_BUILD)
target_compile_features(soda_runtime PUBLIC cxx_std_23)
target_link_libraries(soda_runtime PRIVATE PkgConfig::Libuv)

add_library(soda_native_core INTERFACE)
target_link_libraries(soda_native_core INTERFACE
  soda_document
  soda_cpp_analysis
  soda_indentation
)
