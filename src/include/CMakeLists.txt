# C API for SeekDB
# Provides C API for multi-language bindings (Node.js N-API, FFI, Rust, Go, etc.)

# Note: ENABLE_INITIAL_EXEC_TLS_MODEL removal is handled in src/CMakeLists.txt
# before observer subdirectory is added, ensuring liboceanbase.so uses local-dynamic TLS
# TLS model is controlled by BUILD_EMBED_MODE in cmake/Env.cmake

# Set source files
set(FFI_SOURCES
  seekdb.cpp
)

# Create object library for FFI
ob_set_subtarget(seekdb_object_list common
  ${FFI_SOURCES}
)

ob_add_new_object_target(seekdb_objects seekdb_object_list)

target_include_directories(seekdb_objects
  PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_SOURCE_DIR}/src/libtable/src
)

# Link against oceanbase for object compilation (headers/symbols)
target_link_libraries(seekdb_objects PUBLIC oceanbase)

# Create self-contained shared library for FFI
# This statically links liboceanbase_static.a into libseekdb.so
# so users only need this single .so file
add_library(seekdb
  SHARED
  ${FFI_SOURCES}
)

target_include_directories(seekdb
  PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_SOURCE_DIR}/src/libtable/src
)

# Link oceanbase_static into the shared library
# Use --whole-archive to include all symbols from static library
# Use -static-libstdc++ and -static-libgcc to avoid runtime dependency on system C++ libraries
# Use version script to hide internal symbols (especially malloc/free) to avoid conflicts with V8
target_link_libraries(seekdb
  PRIVATE
    -Wl,--whole-archive
    oceanbase_static
    -Wl,--no-whole-archive
    -static-libstdc++
    -static-libgcc
    -Wl,--allow-multiple-definition
    -Wl,--version-script=${CMAKE_CURRENT_SOURCE_DIR}/seekdb.version
)

# Set library name
set_target_properties(seekdb PROPERTIES
  OUTPUT_NAME "seekdb"
)

# Strip debug symbols in release builds to reduce library size
# This significantly reduces the library size (from ~2.6GB to ~400MB)
# Note: build.sh release uses RelWithDebInfo, not Release
# Strip for all non-Debug builds (Release, RelWithDebInfo, etc.)
if(NOT CMAKE_BUILD_TYPE STREQUAL "Debug" AND NOT CMAKE_BUILD_TYPE STREQUAL "debug")
  add_custom_command(TARGET seekdb POST_BUILD
    COMMAND ${CMAKE_STRIP} $<TARGET_FILE:seekdb>
    COMMENT "Stripping debug symbols from libseekdb to reduce size"
  )
endif()

# Install the shared library and header
install(TARGETS seekdb
  LIBRARY DESTINATION lib
  ARCHIVE DESTINATION lib
  RUNTIME DESTINATION bin
)

install(FILES seekdb.h
  DESTINATION include
)

