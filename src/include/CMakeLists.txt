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

# Create self-contained shared library for FFI (target name: libseekdb to avoid
# conflict with the seekdb custom target in src/observer/CMakeLists.txt)
# This statically links liboceanbase_static.a into libseekdb.so
# so users only need this single .so file
add_library(libseekdb
  SHARED
  ${FFI_SOURCES}
)

target_include_directories(libseekdb
  PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_SOURCE_DIR}/src/libtable/src
)

# Link oceanbase_static into the shared library
# Use --whole-archive (Linux) / -all_load (macOS) to include all symbols from static library
# On Linux: -static-libstdc++ and -static-libgcc to avoid runtime dependency on system C++ libraries
# (macOS/clang does not support -static-libgcc/-static-libstdc++)
# Use version script (Linux) / exported_symbols_list (macOS) to hide internal symbols
if(APPLE)
  # macOS: use -force_load only for liboceanbase_static.a to avoid -all_load pulling in both
  # oblib (with its snappy/lz4) and deps/3rd liblz4.a/libsnappy.a, which causes 68 duplicate symbols.
  # Linking oceanbase_static without -all_load may yield undefined symbols; if so we need to revisit.
  target_link_options(libseekdb PRIVATE "LINKER:-force_load,$<TARGET_FILE:oceanbase_static>")
  target_link_libraries(libseekdb
    PRIVATE
      oceanbase_static
      -Wl,-exported_symbols_list,${CMAKE_CURRENT_SOURCE_DIR}/seekdb_export.txt
  )
else()
  target_link_libraries(libseekdb
    PRIVATE
      -Wl,--whole-archive
      oceanbase_static
      -Wl,--no-whole-archive
      -static-libstdc++
      -static-libgcc
      -Wl,--allow-multiple-definition
      -Wl,--version-script=${CMAKE_CURRENT_SOURCE_DIR}/seekdb.version
  )
endif()

# Output file name remains libseekdb.so / libseekdb.dylib
set_target_properties(libseekdb PROPERTIES
  OUTPUT_NAME "seekdb"
)

# Strip debug symbols in release builds to reduce library size
if(NOT CMAKE_BUILD_TYPE STREQUAL "Debug" AND NOT CMAKE_BUILD_TYPE STREQUAL "debug")
  if(APPLE)
    # macOS: -S strip __DWARF (debug), -x strip local symbol table; full strip fails due to indirect symbol table
    add_custom_command(TARGET libseekdb POST_BUILD
      COMMAND ${CMAKE_STRIP} -Sx $<TARGET_FILE:libseekdb>
      COMMENT "Stripping debug and local symbols from libseekdb (macOS)"
    )
  else()
    add_custom_command(TARGET libseekdb POST_BUILD
      COMMAND ${CMAKE_STRIP} $<TARGET_FILE:libseekdb>
      COMMENT "Stripping debug symbols from libseekdb to reduce size"
    )
  endif()
endif()

# Install the shared library and header
install(TARGETS libseekdb
  LIBRARY DESTINATION lib
  ARCHIVE DESTINATION lib
  RUNTIME DESTINATION bin
)

install(FILES seekdb.h
  DESTINATION include
)
