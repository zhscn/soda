include_guard(GLOBAL)

find_program(SODA_CHEZ_SCHEME_EXECUTABLE NAMES scheme chezscheme REQUIRED)
find_program(SODA_XXD_EXECUTABLE NAMES xxd REQUIRED)

file(REAL_PATH "${SODA_CHEZ_SCHEME_EXECUTABLE}" SODA_CHEZ_SCHEME_REALPATH)
get_filename_component(SODA_CHEZ_RUNTIME_DIR
  "${SODA_CHEZ_SCHEME_REALPATH}"
  DIRECTORY
)

find_path(SODA_CHEZ_INCLUDE_DIR
  NAMES scheme.h
  HINTS "${SODA_CHEZ_RUNTIME_DIR}"
  NO_DEFAULT_PATH
  REQUIRED
)
find_file(SODA_CHEZ_PETITE_BOOT
  NAMES petite.boot
  HINTS "${SODA_CHEZ_RUNTIME_DIR}"
  NO_DEFAULT_PATH
  REQUIRED
)
find_file(SODA_CHEZ_SCHEME_BOOT
  NAMES scheme.boot
  HINTS "${SODA_CHEZ_RUNTIME_DIR}"
  NO_DEFAULT_PATH
  REQUIRED
)
find_library(SODA_CHEZ_KERNEL_LIBRARY
  NAMES kernel libkernel.a
  HINTS "${SODA_CHEZ_RUNTIME_DIR}"
  NO_DEFAULT_PATH
  REQUIRED
)

function(soda_embed_chez_application target)
  set(options)
  set(one_value_args SOURCE_DIR PROGRAM)
  set(multi_value_args SOURCES)
  cmake_parse_arguments(SODA_CHEZ
    "${options}"
    "${one_value_args}"
    "${multi_value_args}"
    ${ARGN}
  )

  if(NOT SODA_CHEZ_SOURCE_DIR OR NOT SODA_CHEZ_PROGRAM)
    message(FATAL_ERROR
      "soda_embed_chez_application requires SOURCE_DIR and PROGRAM"
    )
  endif()

  set(generated_dir "${CMAKE_CURRENT_BINARY_DIR}/generated/chez")
  set(staging_dir "${generated_dir}/scheme")
  set(core_boot "${generated_dir}/soda-core.boot")
  set(petite_boot_raw_c "${generated_dir}/petite_boot.raw.c")
  set(scheme_boot_raw_c "${generated_dir}/scheme_boot.raw.c")
  set(petite_boot_c "${generated_dir}/petite_boot.c")
  set(scheme_boot_c "${generated_dir}/scheme_boot.c")
  set(core_boot_raw_c "${generated_dir}/soda_core_boot.raw.c")
  set(core_boot_c "${generated_dir}/soda_core_boot.c")
  set(core_boot_program_so "${core_boot}.program.so")
  set(core_boot_program_wpo "${core_boot}.program.wpo")
  set(core_boot_whole_so "${core_boot}.whole.so")

  add_custom_command(
    OUTPUT
      "${petite_boot_c}"
      "${scheme_boot_c}"
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${generated_dir}"
    COMMAND
      "${SODA_XXD_EXECUTABLE}"
      -i
      -n soda_petite_boot
      "${SODA_CHEZ_PETITE_BOOT}"
      "${petite_boot_raw_c}"
    COMMAND
      "${CMAKE_COMMAND}"
      "-DINPUT=${petite_boot_raw_c}"
      "-DOUTPUT=${petite_boot_c}"
      -DARRAY=soda_petite_boot
      -DSECTION=.petite.boot
      -P "${PROJECT_SOURCE_DIR}/cmake/annotate-boot-section.cmake"
    COMMAND
      "${SODA_XXD_EXECUTABLE}"
      -i
      -n soda_scheme_boot
      "${SODA_CHEZ_SCHEME_BOOT}"
      "${scheme_boot_raw_c}"
    COMMAND
      "${CMAKE_COMMAND}"
      "-DINPUT=${scheme_boot_raw_c}"
      "-DOUTPUT=${scheme_boot_c}"
      -DARRAY=soda_scheme_boot
      -DSECTION=.scheme.boot
      -P "${PROJECT_SOURCE_DIR}/cmake/annotate-boot-section.cmake"
    DEPENDS
      "${SODA_CHEZ_PETITE_BOOT}"
      "${SODA_CHEZ_SCHEME_BOOT}"
      "${PROJECT_SOURCE_DIR}/cmake/annotate-boot-section.cmake"
    COMMENT "Embedding Chez base boot files"
    VERBATIM
  )

  add_custom_command(
    OUTPUT
      "${core_boot}"
      "${core_boot_c}"
    COMMAND "${CMAKE_COMMAND}" -E rm -rf "${staging_dir}"
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${generated_dir}"
    COMMAND "${CMAKE_COMMAND}" -E copy_directory
      "${SODA_CHEZ_SOURCE_DIR}"
      "${staging_dir}"
    COMMAND
      "${SODA_CHEZ_SCHEME_EXECUTABLE}"
      --script
      "${PROJECT_SOURCE_DIR}/cmake/build-soda-boot.ss"
      "${staging_dir}"
      "${SODA_CHEZ_PROGRAM}"
      "${core_boot}"
    COMMAND
      "${SODA_XXD_EXECUTABLE}"
      -i
      -n soda_core_boot
      "${core_boot}"
      "${core_boot_raw_c}"
    COMMAND
      "${CMAKE_COMMAND}"
      "-DINPUT=${core_boot_raw_c}"
      "-DOUTPUT=${core_boot_c}"
      -DARRAY=soda_core_boot
      -DSECTION=.soda_core.boot
      -P "${PROJECT_SOURCE_DIR}/cmake/annotate-boot-section.cmake"
    DEPENDS
      "${PROJECT_SOURCE_DIR}/cmake/build-soda-boot.ss"
      "${PROJECT_SOURCE_DIR}/cmake/annotate-boot-section.cmake"
      "${SODA_CHEZ_PETITE_BOOT}"
      "${SODA_CHEZ_SCHEME_BOOT}"
      ${SODA_CHEZ_SOURCES}
    BYPRODUCTS
      "${core_boot_program_so}"
      "${core_boot_program_wpo}"
      "${core_boot_whole_so}"
    COMMENT "Compiling and embedding the Soda core boot image"
    VERBATIM
  )

  set_source_files_properties(
    "${petite_boot_c}"
    "${scheme_boot_c}"
    "${core_boot_c}"
    PROPERTIES GENERATED TRUE
  )
  target_sources(${target} PRIVATE
    "${petite_boot_c}"
    "${scheme_boot_c}"
    "${core_boot_c}"
  )
endfunction()
