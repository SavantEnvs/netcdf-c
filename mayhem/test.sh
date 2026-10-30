#!/usr/bin/env bash
#
# mayhem/test.sh — RUNS the netCDF-C CTest suite (built by mayhem/build.sh in build-tests/) plus
# known-answer ncgen/ncdump checks; reports CTRF. Does not compile.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
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


BT="$SRC/build-tests"
[ -x "$BT/ncgen/ncgen" ] && [ -x "$BT/ncdump/ncdump" ] || { echo "build-tests missing — mayhem/build.sh must build it" >&2; emit_ctrf netcdf-c 0 1; exit 1; }
NCGEN="$BT/ncgen/ncgen"; NCDUMP="$BT/ncdump/ncdump"

passed=0; failed=0

# 1) Upstream's CTest suite (nc_test known-answer read/write tests, nctest, ncdump/ncgen golden diffs, nczarr).
#    Each ctest case counts once; a run with far fewer cases than upstream ships is a failure.
LOG="$(mktemp)"
( cd "$BT" && ctest --timeout 300 ) >"$LOG" 2>&1
cp=$(grep -cE 'Test +#[0-9]+: .* Passed' "$LOG")
cf=$(grep -cE 'Test +#[0-9]+: .* (\*\*\*|Failed|Timeout|Exception|Not Run)' "$LOG")
passed=$((passed + cp)); failed=$((failed + cf))
[ $((cp + cf)) -ge 60 ] || { echo "ctest ran only $((cp + cf)) cases (expected >=60)" >&2; failed=$((failed + 1)); }
[ "$cf" -eq 0 ] || grep -E 'Failed|\*\*\*' "$LOG" | head -20 >&2

# 2) Known-answer: CDL -> classic netCDF (ncgen) -> CDL (ncdump) must reproduce asserted values, for each format.
W="$(mktemp -d)"
cat > "$W/in.cdl" <<'CDL'
netcdf ka {
dimensions:
	x = 3 ;
	t = UNLIMITED ; // (2 currently)
variables:
	int v(x) ;
		v:units = "m s-1" ;
	double d(t, x) ;
	char name(x) ;
// global attributes:
		:title = "known answer" ;
data:
 v = 11, -22, 33 ;
 d = 1.5, 2.5, 3.5,
     4.5, 5.5, 6.5 ;
 name = "abc" ;
}
CDL
check() { # name expected-substring...
  local name="$1" out="$2"; shift 2
  local ok=1; for s in "$@"; do grep -qF -- "$s" <<<"$out" || { ok=0; echo "known-answer $name: missing '$s'" >&2; }; done
  if [ $ok -eq 1 ]; then passed=$((passed+1)); else failed=$((failed+1)); fi
}
for k in classic 64-bit-offset cdf5; do
  if "$NCGEN" -k "$k" -b -o "$W/$k.nc" "$W/in.cdl" 2>"$W/err"; then
    out="$("$NCDUMP" "$W/$k.nc" 2>&1)"
  else out="ncgen failed: $(cat "$W/err")"; fi
  check "ncgen/ncdump $k" "$out" 'int v(x) ;' 'v:units = "m s-1" ;' ':title = "known answer" ;' \
        'v = 11, -22, 33 ;' 'd =' '1.5, 2.5, 3.5,' '4.5, 5.5, 6.5 ;' 'name = "abc" ;' 't = UNLIMITED ; // (2 currently)'
done
# the format kind is reported correctly
check "ncdump -k classic" "$("$NCDUMP" -k "$W/classic.nc" 2>&1)" 'classic'
check "ncdump -k cdf5" "$("$NCDUMP" -k "$W/cdf5.nc" 2>&1)" 'cdf5'
# a non-netCDF file must be rejected, not read as valid
printf 'this is not a netcdf file\n' > "$W/bad.nc"
if "$NCDUMP" -h "$W/bad.nc" >/dev/null 2>&1; then failed=$((failed+1)); echo "non-netCDF file was accepted" >&2; else passed=$((passed+1)); fi
rm -rf "$W" "$LOG"

emit_ctrf "cmake-ctest" "$passed" "$failed" 0
