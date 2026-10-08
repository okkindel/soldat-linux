find_package(SDL2 REQUIRED)
find_package(OpenAL REQUIRED)
find_package(Freetype REQUIRED)
add_subdirectory(libs/stb)

# Include unit search paths
add_flag_prepend(CMAKE_Pascal_FLAGS "-Fl${CMAKE_SOURCE_DIR}/client/libs")
add_flag_prepend(CMAKE_Pascal_FLAGS "-Fu${CMAKE_SOURCE_DIR}/client/libs")
add_flag_prepend(CMAKE_Pascal_FLAGS
                 "-Fu${CMAKE_SOURCE_DIR}/client/libs/dglOpenGL")
add_flag_prepend(CMAKE_Pascal_FLAGS "-Fu${CMAKE_SOURCE_DIR}/client/libs/stb")
add_flag_prepend(CMAKE_Pascal_FLAGS
                 "-Fu${CMAKE_SOURCE_DIR}/client/libs/FreeType")
add_flag_prepend(CMAKE_Pascal_FLAGS "-Fu${CMAKE_SOURCE_DIR}/client/libs/openal")

# source files
file(GLOB_RECURSE sources CONFIGURE_DEPENDS "${CMAKE_SOURCE_DIR}/client/*"
     "${CMAKE_SOURCE_DIR}/shared/*.pas" "${CMAKE_SOURCE_DIR}/3rdparty/*.pas"
     "${CMAKE_SOURCE_DIR}/3rdparty/*.inc")

set_source_files_properties(soldat.lpr PROPERTIES OBJECT_DEPENDS "${sources}")

add_executable(soldat soldat.lpr)

if(ADD_ASSETS)
  add_dependencies(soldat soldat_smod soldat_font)
endif()

if(LEGACY_CLIENT_ENABLED)
  add_dependencies(soldat soldat_legacy_client)
endif()

if(UNIX)
  target_link_libraries(soldat stb)
endif()

if(BUILD_STEAM)
  target_link_libraries(soldat steam_api)
else()
  target_link_libraries(soldat GameNetworkingSockets)
endif()

install(
  PROGRAMS ${EXECUTABLE_OUTPUT_PATH}/$<TARGET_FILE_NAME:soldat>
  DESTINATION "${target_binary_install_dir}"
)
if(ADD_ASSETS)
  install(
    FILES "${EXECUTABLE_OUTPUT_PATH}/play-regular.ttf"
    # FIXME: this should be target_data_install_dir, but soldat can't discover it there
    # (needs wrapper script or some equivalent global config)
    DESTINATION "${target_binary_install_dir}"
  )
endif()
