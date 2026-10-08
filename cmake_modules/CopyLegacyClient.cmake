# Script mode helper for SoldatLegacyClient.cmake.
# Copies SOURCE_DIR to TARGET_DIR without overwriting files in configs/.
file(GLOB_RECURSE LEGACY_FILES RELATIVE ${SOURCE_DIR} ${SOURCE_DIR}/*)

foreach(LEGACY_FILE ${LEGACY_FILES})
  set(DESTINATION ${TARGET_DIR}/${LEGACY_FILE})
  if(LEGACY_FILE MATCHES "^configs/" AND EXISTS ${DESTINATION})
    continue()
  endif()

  get_filename_component(DESTINATION_DIR ${DESTINATION} DIRECTORY)
  file(MAKE_DIRECTORY ${DESTINATION_DIR})
  execute_process(COMMAND ${CMAKE_COMMAND} -E copy_if_different
    ${SOURCE_DIR}/${LEGACY_FILE} ${DESTINATION})
endforeach()
