#!/usr/bin/env bash
# Build libseekdb, on macOS bundle deps to libs/, then pack lib + libs/ + seekdb.h into libseekdb-<os>-<arch>.zip
# Build product is written to TOP_DIR/build_libseekdb, then moved to package/libseekdb/ (this script's directory).
#
# Usage:
#   cd package/libseekdb && ./libseekdb-build.sh
#   BUILD_TYPE=debug ./libseekdb-build.sh
#   ./libseekdb-build.sh /path/to/dir-with-libseekdb   # skip build and bundle, pack from existing dir

set -e

# --- Paths and config ---
CURDIR="$PWD"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOP_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_TYPE="${BUILD_TYPE:-release}"
BUILD_DIR="$TOP_DIR/build_${BUILD_TYPE}"
PACKAGE_BUILD_DIR="$TOP_DIR/build_libseekdb"
WORK_DIR=""
UNAME_S="$(uname -s)"
UNAME_M="$(uname -m)"

# --- Helpers ---
die() { echo "error: $*" >&2; exit 1; }

# List dependency paths from a dylib (one per line, trimmed). Skips first line (the dylib itself).
get_dylib_deps() {
  local dylib="$1"
  otool -L "$dylib" | tail -n +2 | while IFS= read -r line; do
    dep="${line%% (*}"
    printf '%s\n' "$(printf '%s' "$dep" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  done
}

# Change a dependency reference in dylib: from_ref -> to_ref (exact match).
fix_dylib_ref() {
  local dylib="$1" from_ref="$2" to_ref="$3"
  install_name_tool -change "$from_ref" "$to_ref" "$dylib"
}

# Remove all LC_RPATH entries from dylib that look like absolute paths.
strip_rpaths() {
  local dylib="$1"
  while IFS= read -r rpath; do
    [[ -n "$rpath" ]] || continue
    echo "  delete_rpath: $rpath"
    install_name_tool -delete_rpath "$rpath" "$dylib"
  done < <(otool -l "$dylib" | awk '/[[:space:]]path[[:space:]]+\// { print $2 }')
}

# --- 1) Resolve WORK_DIR ---
if [[ -n "${1:-}" ]]; then
  WORK_DIR="$(cd "$1" && pwd)"
  echo "[BUILD] Using existing directory: $WORK_DIR (skip build and bundle)"
else
  WORK_DIR="$BUILD_DIR/src/include"

  # --- 2) Build libseekdb if not present (main lib is always next to libs/, not inside) ---
  if [[ ! -f "$WORK_DIR/libseekdb.dylib" && ! -f "$WORK_DIR/libseekdb.so" ]]; then
    echo "[BUILD] Building libseekdb (BUILD_TYPE=$BUILD_TYPE)..."
    if [[ ! -d "$BUILD_DIR" ]]; then
      (cd "$TOP_DIR" && ./build.sh "$BUILD_TYPE" --init --make) || exit 1
    else
      (cd "$TOP_DIR" && ./build.sh "$BUILD_TYPE" --make) || exit 1
    fi
  fi

  # --- 3) macOS: bundle deps to libs/, fix @loader_path ---
  # Layout: libseekdb.dylib at root, deps in libs/. When main is loaded from root,
  # @loader_path = root, so main's deps must be @loader_path/libs/xxx. When a dep in libs/
  # is loaded, @loader_path = libs/, so dep refs must be @loader_path/xxx (not libs/xxx).
  if [[ "$UNAME_S" == "Darwin" && -f "$WORK_DIR/libseekdb.dylib" ]]; then
    echo "[BUILD] Bundling libseekdb.dylib for macOS..."
    cd "$WORK_DIR"
    DYLIB_NAME="libseekdb.dylib"

    strip_rpaths "$DYLIB_NAME"

    if ! command -v dylibbundler &>/dev/null; then
      die "dylibbundler not found. Install with: brew install dylibbundler"
    fi
    rm -rf libs && mkdir -p libs
    dylibbundler -x "$DYLIB_NAME" -cd -b -p '@loader_path/libs'

    install_name_tool -id "@loader_path/$DYLIB_NAME" "$DYLIB_NAME"
    while IFS= read -r dep; do
      [[ -n "$dep" ]] || continue
      if [[ "$dep" == @loader_path/* ]]; then
        depname="${dep#@loader_path/}"
        [[ -f "libs/$depname" ]] && fix_dylib_ref "$DYLIB_NAME" "$dep" "@loader_path/libs/$depname"
      fi
    done < <(get_dylib_deps "$DYLIB_NAME")

    for d in libs/*.dylib; do
      [[ -f "$d" ]] || continue
      name="$(basename "$d")"
      while IFS= read -r dep; do
        [[ -n "$dep" ]] || continue
        if [[ "$dep" == @loader_path/libs/* ]]; then
          fix_dylib_ref "$d" "$dep" "@loader_path/${dep#@loader_path/libs/}"
        elif [[ "$dep" == @rpath/libs/* ]]; then
          fix_dylib_ref "$d" "$dep" "@loader_path/${dep#@rpath/libs/}"
        fi
      done < <(get_dylib_deps "$d")
      install_name_tool -id "@loader_path/$name" "$d"
    done

    echo "[BUILD] Bundle done: $DYLIB_NAME at root, deps in $WORK_DIR/libs"
    cd - >/dev/null
  fi
fi

# --- 4) Resolve main library and deps dir (main and libs/ are siblings) ---
MAIN_LIB=""
DEPS_DIR="$WORK_DIR/libs"
if [[ -f "$WORK_DIR/libseekdb.dylib" ]]; then
  MAIN_LIB="$WORK_DIR/libseekdb.dylib"
elif [[ -f "$WORK_DIR/libseekdb.so" ]]; then
  MAIN_LIB="$WORK_DIR/libseekdb.so"
else
  die "libseekdb.dylib or libseekdb.so not found in $WORK_DIR"
fi

HEADER="$TOP_DIR/src/include/seekdb.h"
[[ -f "$HEADER" ]] || die "seekdb.h not found: $HEADER"

# --- 5) OS / Arch for zip name ---
case "$UNAME_S" in
  Darwin) OS="darwin" ;;
  Linux)  OS="linux"  ;;
  *)      die "unsupported OS: $UNAME_S" ;;
esac
if [[ -n "${ARCH:-}" ]]; then
  echo "[BUILD] Using ARCH from environment: $ARCH"
else
  case "$UNAME_M" in
    arm64|aarch64) ARCH="arm64"   ;;
    x86_64|amd64)  ARCH="x86_64" ;;
    *)             die "unsupported arch: $UNAME_M" ;;
  esac
fi
ARCH_SUFFIX="${ARCH}"
[[ "$ARCH" == "x86_64" ]] && ARCH_SUFFIX="x64"
ZIP_NAME="libseekdb-${OS}-${ARCH_SUFFIX}.zip"
MAIN_LIB_NAME="$(basename "$MAIN_LIB")"

# --- 6) Assemble and zip ---
mkdir -p "$PACKAGE_BUILD_DIR"
OUTPUT_ZIP="$PACKAGE_BUILD_DIR/$ZIP_NAME"
PACK_DIR="$(mktemp -d)"
trap "rm -rf '$PACK_DIR'" EXIT

cp "$HEADER" "$PACK_DIR/seekdb.h"
cp "$MAIN_LIB" "$PACK_DIR/$MAIN_LIB_NAME"
if [[ -d "$DEPS_DIR" ]]; then
  mkdir -p "$PACK_DIR/libs"
  for f in "$DEPS_DIR"/*; do
    [[ -f "$f" ]] || continue
    cp "$f" "$PACK_DIR/libs/"
  done
fi

(cd "$PACK_DIR" && zip -r "$OUTPUT_ZIP" . -x "*.DS_Store")
mv "$OUTPUT_ZIP" "$SCRIPT_DIR/" || exit 2
echo "[BUILD] Created: $SCRIPT_DIR/$ZIP_NAME"
