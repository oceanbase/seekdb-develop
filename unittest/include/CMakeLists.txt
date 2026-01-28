# Test program for SeekDB C API
# Only build this test when BUILD_EMBED_MODE is enabled, as the seekdb library
# is only created in BUILD_EMBED_MODE to avoid conflict with the seekdb custom target
# in src/observer/CMakeLists.txt
if(BUILD_EMBED_MODE)
  add_executable(test_seekdb
    test_seekdb.cpp
  )

  target_include_directories(test_seekdb
    PRIVATE
      ${CMAKE_SOURCE_DIR}/src/include
      ${CMAKE_CURRENT_SOURCE_DIR}
      ${CMAKE_SOURCE_DIR}/unittest
  )

  target_link_libraries(test_seekdb
    PRIVATE
      seekdb
  )

  # Add test target
  add_test(NAME test_seekdb COMMAND test_seekdb)
  set_tests_properties(test_seekdb PROPERTIES TIMEOUT 300)
endif() # BUILD_EMBED_MODE

