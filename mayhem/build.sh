#!/usr/bin/env bash
#
# mayhem/build.sh — builds the sanitized fuzz harness (+ standalone reproducer) and the netCDF test
# suite. Runs in the commit image as `mayhem` in /mayhem (SRC); build knobs come from the base ENV.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# netCDF-3 formats only (classic/64-bit/CDF-5), mirroring OSS-Fuzz's projects/netcdf build: no HDF5,
# no DAP/byte-range. Nothing is fetched at build time, so the offline PATCH re-run works.
# CC (exported above) selects the compiler; passing -DCMAKE_C_COMPILER would invalidate the cmake cache on a re-run.
NC_OPTS="-DBUILD_SHARED_LIBS=OFF -DNETCDF_ENABLE_HDF5=OFF -DNETCDF_ENABLE_DAP=OFF -DNETCDF_ENABLE_BYTERANGE=OFF"

# 1) Test suite first, with the project's NORMAL flags (clean, independent of the sanitized build).
#    upstream's CMakeLists adds the fuzz/ dir whenever LIB_FUZZING_ENGINE is in the environment; unset it here.
env -u LIB_FUZZING_ENGINE cmake -B build-tests $NC_OPTS -DNETCDF_ENABLE_TESTS=ON \
    -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" >/dev/null
env -u LIB_FUZZING_ENGINE cmake --build build-tests -j"$MAYHEM_JOBS"

# 2) Project itself with sanitizers + DWARF<4 (libnetcdf.a, no tests); the harness is upstream's
#    fuzz/fuzz_open.c, built by its own CMake target.
# fuzzer-no-link: libFuzzer coverage instrumentation in the library and harness (the engine itself is linked below)
CFLAGS_FUZZ="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link -O1 $DEBUG_FLAGS"
cmake -B build $NC_OPTS -DNETCDF_ENABLE_TESTS=OFF \
      -DCMAKE_C_FLAGS="$CFLAGS_FUZZ" >/dev/null
cmake --build build -j"$MAYHEM_JOBS" --target netcdf fuzz_open

# 3) Relink the harness: libFuzzer binary and a standalone run-once reproducer, both with LSan off.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o build/lsan_off.o
NC_LIBS="build/libnetcdf.a -ldl -lm -lz"
$CC $CFLAGS_FUZZ -c fuzz/fuzz_open.c -I include -o build/fuzz_open.o
$CC $CFLAGS_FUZZ $LIB_FUZZING_ENGINE build/fuzz_open.o build/lsan_off.o $NC_LIBS -o /mayhem/fuzz_open
$CC $CFLAGS_FUZZ -c "$STANDALONE_FUZZ_MAIN" -o build/standalone_main.o
$CC $CFLAGS_FUZZ build/standalone_main.o build/fuzz_open.o build/lsan_off.o $NC_LIBS -o /mayhem/fuzz_open-standalone
