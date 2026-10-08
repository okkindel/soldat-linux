# Downloads the official native Linux build of Soldat 1.7 during configure
# step. The main menu starts it for servers that still use the 1.7 network
# protocol. The build is not part of this repository, it is fetched from
# soldat.pl (see https://wiki.soldat.pl/index.php/Soldat_on_macOS_and_Linux).
macro(download_legacy_client)
  set(LEGACY_CLIENT_URL "https://update.soldat.pl/updates/soldat_linux.zip"
      CACHE STRING "Archive with the native Soldat 1.7 Linux client")
  set(LEGACY_CLIENT_SHA256
      "b5131ee79528b50974ef7ccd1d143ef45817ad044e844afc66cb62a4ff576a4f"
      CACHE STRING "Expected SHA256 of the legacy client archive")

  set(LEGACY_DOWNLOADS_DIR ${CMAKE_BINARY_DIR}/downloads)
  set(LEGACY_ARCHIVE ${LEGACY_DOWNLOADS_DIR}/soldat_linux.zip)
  set(LEGACY_EXTRACT_DIR ${LEGACY_DOWNLOADS_DIR}/legacy)

  message(STATUS "Soldat 1.7 Linux client will be downloaded from ${LEGACY_CLIENT_URL}")
  file(DOWNLOAD
    ${LEGACY_CLIENT_URL}
    ${LEGACY_ARCHIVE}
    EXPECTED_HASH SHA256=${LEGACY_CLIENT_SHA256}
  )

  if(NOT EXISTS ${LEGACY_EXTRACT_DIR}/soldat_linux/soldat_x64)
    file(MAKE_DIRECTORY ${LEGACY_EXTRACT_DIR})
    execute_process(
      COMMAND ${CMAKE_COMMAND} -E tar xf ${LEGACY_ARCHIVE}
      WORKING_DIRECTORY ${LEGACY_EXTRACT_DIR}
      RESULT_VARIABLE LEGACY_EXTRACT_RESULT
    )
    if(NOT LEGACY_EXTRACT_RESULT EQUAL 0)
      message(FATAL_ERROR "Could not extract ${LEGACY_ARCHIVE}")
    endif()
    # the launcher and the server are not used
    file(REMOVE
      ${LEGACY_EXTRACT_DIR}/soldat_linux/soldatlauncher-0.1.0.AppImage
      ${LEGACY_EXTRACT_DIR}/soldat_linux/soldatserver_x64
    )
  endif()

  # Copied during build step. Existing configs are kept, so the settings of
  # the legacy client survive rebuilds.
  add_custom_target(
    soldat_legacy_client
    COMMAND ${CMAKE_COMMAND}
            -DSOURCE_DIR=${LEGACY_EXTRACT_DIR}/soldat_linux
            -DTARGET_DIR=${EXECUTABLE_OUTPUT_PATH}/legacy
            -P ${CMAKE_MODULE_PATH}/CopyLegacyClient.cmake
    COMMENT "Copying Soldat 1.7 client to ${EXECUTABLE_OUTPUT_PATH}/legacy"
  )
endmacro()
