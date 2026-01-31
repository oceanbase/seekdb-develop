#!/usr/bin/env bash
# Build libseekdb, on macOS bundle deps to libs/, then pack lib + libs/ + seekdb.h into libseekdb-<os>-<arch>.zip
# Build product is written to TOP_DIR/build_libseekdb, then moved to package/libseekdb/ (this script's directory).
# Usage:
#   cd package/libseekdb && ./libseekdb-build.sh
#   BUILD_TYPE=debug ./libseekdb-build.sh
#   ./libseekdb-build.sh /path/to/dir-with-libseekdb   # skip build and bundle, pack from existing dir

set -e
CURDIR=$PWD
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOP_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_TYPE="${BUILD_TYPE:-release}"
BUILD_DIR="$TOP_DIR/build_${BUILD_TYPE}"
PACKAGE_BUILD_DIR="$TOP_DIR/build_libseekdb"
WORK_DIR=""

echo "[BUILD] args: TOP_DIR=${TOP_DIR} BUILD_TYPE=${BUILD_TYPE} CURDIR=${CURDIR}"

# ---- 1) Resolve WORK_DIR: either from argument or from build ----
if [[ -n "$1" ]]; then
  WORK_DIR="$(cd "$1" && pwd)"
  echo "[BUILD] Using existing directory: $WORK_DIR (skip build and bundle)"
else
  WORK_DIR="$BUILD_DIR/src/include"

  # ---- 2) Build libseekdb if not present ----
  if [[ ! -f "$WORK_DIR/libseekdb.dylib" && ! -f "$WORK_DIR/libseekdb.so" && ! -f "$WORK_DIR/libs/libseekdb.dylib" && ! -f "$WORK_DIR/libs/libseekdb.so" ]]; then
    echo "[BUILD] Building libseekdb (BUILD_TYPE=$BUILD_TYPE)..."
    if [[ ! -d "$BUILD_DIR" ]]; then
      (cd "$TOP_DIR" && ./build.sh "$BUILD_TYPE" --init --make) || exit 1
    else
      (cd "$TOP_DIR" && ./build.sh "$BUILD_TYPE" --make) || exit 1
    fi
  fi

  # ---- 3) macOS: bundle (strip rpaths, copy deps to libs/, fix load paths) ----
  UNAME_S="$(uname -s)"
  if [[ "$UNAME_S" == "Darwin" && -f "$WORK_DIR/libseekdb.dylib" ]]; then
    echo "[BUILD] Bundling libseekdb.dylib for macOS..."
    cd "$WORK_DIR"
    DYLIB_NAME="libseekdb.dylib"

    while IFS= read -r rpath; do
      [[ -z "$rpath" ]] && continue
      echo "  delete_rpath: $rpath"
      install_name_tool -delete_rpath "$rpath" "$DYLIB_NAME"
    done < <(otool -l "$DYLIB_NAME" | grep "deps/3rd/" | awk '{print $2}')

    if ! command -v dylibbundler &>/dev/null; then
      echo "error: dylibbundler not found. Install with: brew install dylibbundler" >&2
      exit 1
    fi
    rm -rf libs
    mkdir -p libs
    dylibbundler -x "$DYLIB_NAME" -cd -b -p '@loader_path/libs'
    mv "$DYLIB_NAME" libs/
    echo "[BUILD] Bundle done: libs/$DYLIB_NAME and deps in $WORK_DIR/libs"
    cd - >/dev/null
  fi
fi

# ---- 4) Resolve main library path for packing ----
MAIN_LIB=""
DEPS_DIR=""
if [[ -f "$WORK_DIR/libs/libseekdb.dylib" ]]; then
  MAIN_LIB="$WORK_DIR/libs/libseekdb.dylib"
  DEPS_DIR="$WORK_DIR/libs"
elif [[ -f "$WORK_DIR/libs/libseekdb.so" ]]; then
  MAIN_LIB="$WORK_DIR/libs/libseekdb.so"
  DEPS_DIR="$WORK_DIR/libs"
elif [[ -f "$WORK_DIR/libseekdb.dylib" ]]; then
  MAIN_LIB="$WORK_DIR/libseekdb.dylib"
  DEPS_DIR="$WORK_DIR/libs"
elif [[ -f "$WORK_DIR/libseekdb.so" ]]; then
  MAIN_LIB="$WORK_DIR/libseekdb.so"
  DEPS_DIR="$WORK_DIR/libs"
else
  echo "error: libseekdb.dylib or libseekdb.so not found in $WORK_DIR (or $WORK_DIR/libs)" >&2
  exit 1
fi

HEADER="$TOP_DIR/src/include/seekdb.h"
if [[ ! -f "$HEADER" ]]; then
  echo "error: seekdb.h not found: $HEADER" >&2
  exit 1
fi

# ---- 5) OS / Arch for zip name ----
UNAME_S="$(uname -s)"
case "$UNAME_S" in
  Darwin)  OS="darwin" ;;
  Linux)   OS="linux"  ;;
  *)       echo "error: unsupported OS: $UNAME_S" >&2; exit 1 ;;
esac

UNAME_M="$(uname -m)"
if [[ -n "${ARCH:-}" ]]; then
  echo "[BUILD] Using ARCH from environment: $ARCH"
else
  case "$UNAME_M" in
    arm64|aarch64)   ARCH="arm64"   ;;
    x86_64|amd64)   ARCH="x86_64" ;;
    *)              echo "error: unsupported arch: $UNAME_M" >&2; exit 1 ;;
  esac
fi

# Zip name uses x64 for x86_64 (linux-x64)
ARCH_SUFFIX="${ARCH}"
[[ "$ARCH" == "x86_64" ]] && ARCH_SUFFIX="x64"
ZIP_NAME="libseekdb-${OS}-${ARCH_SUFFIX}.zip"
MAIN_LIB_NAME="$(basename "$MAIN_LIB")"
mkdir -p "$PACKAGE_BUILD_DIR"
OUTPUT_ZIP="$PACKAGE_BUILD_DIR/$ZIP_NAME"

# ---- 6) Assemble and zip (output to build_libseekdb, then mv to CURDIR) ----
PACK_DIR="$(mktemp -d)"
trap "rm -rf '$PACK_DIR'" EXIT

cp "$HEADER" "$PACK_DIR/seekdb.h"
cp "$MAIN_LIB" "$PACK_DIR/$MAIN_LIB_NAME"

if [[ -d "$DEPS_DIR" ]]; then
  mkdir -p "$PACK_DIR/libs"
  for f in "$DEPS_DIR"/*; do
    [[ -f "$f" ]] || continue
    [[ "$(basename "$f")" == "$MAIN_LIB_NAME" ]] && continue
    cp "$f" "$PACK_DIR/libs/"
  done
fi

(cd "$PACK_DIR" && zip -r "$OUTPUT_ZIP" . -x "*.DS_Store")

mv "$OUTPUT_ZIP" "$SCRIPT_DIR/" || exit 2
echo "[BUILD] Created: $SCRIPT_DIR/$ZIP_NAME"
