if(NOT DEFINED INPUT OR NOT DEFINED OUTPUT OR
   NOT DEFINED ARRAY OR NOT DEFINED SECTION)
  message(FATAL_ERROR
    "annotate-boot-section.cmake requires INPUT, OUTPUT, ARRAY and SECTION")
endif()

file(READ "${INPUT}" content)
string(REPLACE
  "unsigned char ${ARRAY}[] ="
  "unsigned char ${ARRAY}[] __attribute__((section(\"${SECTION}\"), used, aligned(16))) ="
  content
  "${content}")
file(WRITE "${OUTPUT}" "${content}")
