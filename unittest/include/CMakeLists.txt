# Test program for SeekDB C API (links to libseekdb from src/include)
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
    libseekdb
)

# Add test target
add_test(NAME test_seekdb COMMAND test_seekdb)
set_tests_properties(test_seekdb PROPERTIES TIMEOUT 300)

