#!/bin/bash
set -e

cd "$(dirname "$0")"

# Set library path
SEEKDB_LIB_DIR="$(cd ../../../build_release/src/include && pwd)"
export SEEKDB_LIB_PATH="${SEEKDB_LIB_DIR}/libseekdb.so"

echo "=== Testing Go FFI Binding ==="
echo "SEEKDB_LIB_PATH: $SEEKDB_LIB_PATH"
echo ""

# Check if seekdb library exists
if [ ! -f "${SEEKDB_LIB_DIR}/libseekdb.so" ]; then
    echo "Error: libseekdb.so not found at ${SEEKDB_LIB_DIR}/libseekdb.so"
    echo "Please build the project first: cd ../../../build_release && make libseekdb"
    exit 1
fi

# Check if go is available
if ! command -v go >/dev/null 2>&1; then
    echo "Error: go command not found"
    echo "Please install Go first"
    exit 1
fi

# Clean up old database directory if it exists to start fresh
DB_DIR="./seekdb.db"
if [ -d "${DB_DIR}" ]; then
    echo "Cleaning up old database directory..."
    rm -rf "${DB_DIR}"
    echo "Old database directory removed."
    echo ""
fi

# Run the test
echo "Running Go tests..."
echo ""
# Note: C ABI layer handles SIGSEGV gracefully during static destructors
# Exit code is 0 and no segfault messages are output
go run test.go

echo ""
echo "Test completed!"
