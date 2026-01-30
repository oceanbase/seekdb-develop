# libseekdb package

## Build

```bash
./libseekdb-build.sh
```

Output: `libseekdb-<os>-<arch>.zip` (e.g. `libseekdb-darwin-arm64.zip`) is created in this directory.

## Package contents and standalone distribution

Zip layout:

```
seekdb.h           # C API header
libseekdb.dylib    # Main library (macOS) or libseekdb.so (Linux)
libs/              # Dependency dylibs (macOS only; collected by dylibbundler)
  *.dylib
```

- **Standalone distribution**: After extraction, the package can be used by other projects without this repo or the build environment.
- **macOS**: The main library and its dependencies use relative paths (`@loader_path/libs`). Unzip to any directory and keep the main library and `libs/` at the same level so they load correctly.
- **Linux**: Usually has no extra dependencies or relies on system libraries; unzip and use as-is.

### How to use (standalone)

1. Unzip to a target directory, e.g. `/opt/seekdb-sdk/`:
   ```
   /opt/seekdb-sdk/
     seekdb.h
     libseekdb.dylib
     libs/
       libfoo.dylib
       ...
   ```

2. Point your build at the header and library, e.g.:
   ```bash
   gcc -I/opt/seekdb-sdk -L/opt/seekdb-sdk -lseekdb ...
   ```
   At runtime on macOS, the main library loads dependencies from `libs/` in the same directory; you do not need to set `DYLD_LIBRARY_PATH`.

3. If the main library and the executable are in different directories (e.g. executable in `bin/`, library in `lib/`), ensure `libs/` exists next to the main library, or put the dependencies where the system can find them and set `DYLD_LIBRARY_PATH` (not recommended; prefer keeping the zip layout).

### Notes

- **OS and architecture**: The zip name reflects the build OS and CPU (e.g. darwin-arm64, darwin-x86_64, linux-x86_64); use the matching zip for the target environment.
- **Rebuilding**: After changing loader path or dependencies, run `libseekdb-build.sh` again to produce a new zip.
