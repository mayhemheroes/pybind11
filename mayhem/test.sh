#!/usr/bin/env bash
#
# pybind11/mayhem/test.sh — build + RUN a self-contained functional oracle (mayhem/oracle.cpp) over
# the SAME pybind11 embedded-interpreter + type-caster path the fuzzer drives, then emit a CTRF
# summary. exit 0 iff no check failed.
#
# WHY a golden oracle (not pybind11's own pytest suite): pybind11's `tests/` are paired C++/Python
# modules that require a full `pip install .`, network downloads (Catch/Eigen), numpy/scipy/pytest
# and a writable build — none appropriate for a deterministic, offline, build-time PATCH gate. The
# oracle instead embeds CPython exactly as the harness does and asserts real conversions
# (py::exec → int/str casters, os.attr() call, Decimal construct+sqrt, py::str UTF-8 round-trip).
# A no-op patch to the casters / embed.h cannot pass: every check reads a value back and compares it
# to a golden expectation. Built with NORMAL flags (no sanitiser) so it is an honest oracle.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${CXX:=clang++}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

ORACLE_SRC="$SRC/mayhem/oracle.cpp"
ORACLE_BIN="/tmp/pybind11_oracle"
PY_INC="$(python3-config --includes)"
PY_LDFLAGS="$(python3-config --ldflags --embed)"

# Build with NORMAL flags (no SANITIZER_FLAGS) into a clean binary.
echo "=== building pybind11 oracle ==="
if ! env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
     "$CXX" -std=c++17 -pthread -I"$SRC/include" $PY_INC \
       "$ORACLE_SRC" $PY_LDFLAGS -o "$ORACLE_BIN" >/tmp/pb-build.log 2>&1; then
  echo "oracle build failed:" >&2; tail -40 /tmp/pb-build.log >&2
  emit_ctrf "pybind11-oracle" 0 1 0; exit 2
fi

echo "=== running pybind11 oracle ==="
out="$("$ORACLE_BIN" 2>&1)"; rc=$?
echo "$out"

# Count per-CHECK results from the oracle's [ PASS ]/[ FAIL ] lines.
PASSED=$(printf '%s\n' "$out" | grep -c '^\[ PASS \]')
FAILED=$(printf '%s\n' "$out" | grep -c '^\[ FAIL \]')
: "${PASSED:=0}" "${FAILED:=0}"

# No parseable checks at all → fall back to exit code (e.g. a crash before any CHECK).
if [ "$(( PASSED + FAILED ))" -eq 0 ]; then
  echo "no CHECK lines parsed; using oracle exit code $rc" >&2
  [ "$rc" -eq 0 ] && { emit_ctrf "pybind11-oracle" 1 0 0; exit 0; }
  emit_ctrf "pybind11-oracle" 0 1 0; exit 1
fi

# A nonzero exit with no parsed failures still means failure (e.g. a late crash).
if [ "$rc" -ne 0 ] && [ "$FAILED" -eq 0 ]; then FAILED=1; fi

emit_ctrf "pybind11-oracle" "$PASSED" "$FAILED" 0
