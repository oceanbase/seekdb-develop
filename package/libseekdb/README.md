# libseekdb package

Portable C library build of libseekdb for Linux and macOS (x64 and arm64). Output is a zip containing `seekdb.h` and `libseekdb.so` (Linux) or `libseekdb.dylib` (macOS), suitable for standalone use.

## Build

```bash
./libseekdb-build.sh
```

Output: `libseekdb-<os>-<arch>.zip` is created in this directory. Arch is `x64` (for x86_64) or `arm64`, e.g. `libseekdb-darwin-x64.zip`, `libseekdb-linux-x64.zip`, `libseekdb-darwin-arm64.zip`, `libseekdb-linux-arm64.zip`.

### Reference build environments (CI)

The supported systems and environments are defined by the GitHub Actions workflow [`.github/workflows/build-libseekdb.yml`](../../.github/workflows/build-libseekdb.yml). The workflow builds on push/PR and optionally uploads zips to S3 when **DESTINATION_TARGET_PATH** (e.g. `s3://bucket/libseekdb/<sha>`) or **AWS_S3_BUCKET** and AWS credentials are configured.

| Platform    | Zip name                  | Runner / container                                      | Deps profile              |
| ----------- | ------------------------- | ------------------------------------------------------- | ------------------------- |
| Linux x64   | libseekdb-linux-x64.zip   | ubuntu-22.04 + quay.io/pypa/manylinux2014_x86_64        | oceanbase.el7.x86_64.deps |
| Linux arm64 | libseekdb-linux-arm64.zip | ubuntu-22.04-arm + quay.io/pypa/manylinux2014_aarch64    | oceanbase.el7.aarch64.deps |
| macOS x64   | libseekdb-darwin-x64.zip  | macos-13 (cross-build)                                  | oceanbase.macos.arm64.deps |
| macOS arm64 | libseekdb-darwin-arm64.zip| macos-13 (native)                                       | oceanbase.macos.arm64.deps |

Use these systems and deps as the standard when building or consuming libseekdb.

### Linux glibc compatibility

CI Linux builds use **pypa/manylinux2014** (CentOS 7–based), which ships **glibc 2.17**. The prebuilt `libseekdb.so` therefore requires **GLIBC_2.17** or newer on the target system, **including CentOS 7**.

- **Supported (glibc ≥ 2.17)**: CentOS 7 / RHEL 7, CentOS 8 / RHEL 8, AlmaLinux 7/8, Rocky Linux 8/9, Ubuntu 18.04+, Debian 10+, Fedora 25+, and most distros from about 2014 onward. This covers current and legacy Linux environments, including CentOS 7.
- **Not supported (glibc &lt; 2.17)**: CentOS 6 (2.12) and older distros. For these, build libseekdb locally on the target system.

To check your system: `ldd --version` or `getconf GNU_LIBC_VERSION`.

### macOS compatibility

CI macOS builds use **macOS 13** runners and set **CMAKE_OSX_DEPLOYMENT_TARGET=11.0**, so the prebuilt `libseekdb.dylib` runs on **macOS 11 (Big Sur) and later** (12, 13, 14, 15). Setting the deployment target to 11.0 allows use on most current and recent macOS versions.

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

- **OS and architecture**: The zip name reflects the build OS and CPU: `darwin-x64`, `darwin-arm64`, `linux-x64`, `linux-arm64` (x64 = x86_64). Use the matching zip for the target environment. On Linux, the prebuilt .so requires glibc ≥ 2.17 (see [Linux glibc compatibility](#linux-glibc-compatibility)), including CentOS 7; on macOS, the prebuilt dylib is built on **macOS 13** with **minimum deployment target 11.0**, so it runs on **macOS 11 (Big Sur) and later** (12, 13, 14, 15).
- **Rebuilding**: After changing loader path or dependencies, run `libseekdb-build.sh` again to produce a new zip.
