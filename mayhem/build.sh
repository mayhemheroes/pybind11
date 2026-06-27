#!/usr/bin/env bash
#
# pybind11/mayhem/build.sh — build the OSS-Fuzz pybind11 harness as a sanitized libFuzzer target
# (+ a standalone run-once reproducer) against pybind11's header-only C++<->Python binding layer.
#
# The fuzzed surface is pybind11's EMBEDDED-INTERPRETER + type-caster path. The harness
# (mayhem/harnesses/pybind_fuzzer.cc) starts a py::scoped_interpreter and, per input, drives:
#   * py::exec(<fuzzed source>)               — compile + run arbitrary Python through pybind11
#   * py::module_::import("os").attr(<bytes>) — attribute lookup with a fuzzed name
#   * decimal.Decimal(<bytes>).<attr>()       — construct + call through pybind11 object wrappers
#   * py::str(<bytes>)                          — string type-caster (UTF-8 decode path)
# Inputs are NOT a file format — FuzzedDataProvider slices the raw bytes into the Python source +
# attribute/argument strings above. pybind11 is HEADER-ONLY: the binding code is instrumented
# because it is #included into the (sanitised) harness translation unit; CPython itself is linked
# in unsanitised via libpython (we are fuzzing pybind11's wrappers, not the interpreter).
#
# Build contract comes from the org base ENV (CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC/
# STANDALONE_FUZZ_MAIN). One libFuzzer binary + one standalone binary, both into $OUT (/mayhem).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
# DEBUG_FLAGS: emit DWARF-3 symbols (Mayhem triage can't read DWARF >= 4; clang-19 defaults to DWARF-5).
# `:=` so an explicit empty override is preserved if the caller really wants no debug info.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${OUT:=/mayhem}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE STANDALONE_FUZZ_MAIN MAYHEM_JOBS OUT

cd "$SRC"

HARNESS="$SRC/mayhem/harnesses/pybind_fuzzer.cc"
INC="-I$SRC/include"

# Python dev: headers (Python.h) + the shared libpython to link the embedded interpreter against.
# python3-config --embed gives the right -I / -L / -lpython for an EMBEDDING build (the trailing
# m/abiflags and the version are resolved for us, so this tracks whatever python3-dev apt installed).
PY_INC="$(python3-config --includes)"
PY_LDFLAGS="$(python3-config --ldflags --embed)"
# OSS-Fuzz compiles the harness as C++17; pybind11 requires >= C++11 and embed.h is happiest at 17.
CXXFLAGS_COMMON="-std=c++17 -pthread"

echo "CXX=$CXX  SANITIZER_FLAGS=$SANITIZER_FLAGS"
echo "PY_INC=$PY_INC"
echo "PY_LDFLAGS=$PY_LDFLAGS"

# ── 1) libFuzzer target -> $OUT/pybind_fuzzer ─────────────────────────────────────────────────────
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $CXXFLAGS_COMMON $INC $PY_INC \
    "$HARNESS" $LIB_FUZZING_ENGINE \
    $PY_LDFLAGS \
    -o "$OUT/pybind_fuzzer"

# ── 2) standalone run-once reproducer -> $OUT/pybind_fuzzer-standalone ────────────────────────────
# Compile LLVM's standalone driver as a C object first ($CC) so its extern "C" LLVMFuzzerTestOneInput
# reference matches the harness's C-linkage definition, then link with the C++ harness + libpython.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $CXXFLAGS_COMMON $INC $PY_INC \
    /tmp/standalone_main.o "$HARNESS" \
    $PY_LDFLAGS \
    -o "$OUT/pybind_fuzzer-standalone"

echo "build.sh complete:"
ls -la "$OUT/pybind_fuzzer" "$OUT/pybind_fuzzer-standalone" 2>&1 || true
