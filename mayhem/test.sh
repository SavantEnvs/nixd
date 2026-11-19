#!/usr/bin/env bash
#
# mayhem/test.sh — RUN upstream's offline test suites, which mayhem/build.sh compiled with normal
# flags into mayhem/build/tests/: libnixf's gtest suites (libnixf/test: Basic, Parse, Sema), nixd's
# unit/fork-piped gtest (nixd/test) and nixd's lit regression suite (nixd/tools/nixd/test, the
# meson test regression/nixd), which drives the nixd server binary with LSP sessions and FileChecks
# its replies. exit 0 = pass. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
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

T="$SRC/mayhem/build/tests"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/nixd-test.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
passed=0 failed=0 skipped=0

# gtest <name> <binary>: run one gtest binary and add its JSON report's counts.
gtest() {
  local name="$1" bin="$2" p f k
  if [ ! -x "$bin" ]; then
    echo "missing $bin — run mayhem/build.sh first" >&2
    failed=$((failed + 1)); return
  fi
  "$bin" --gtest_output="json:$OUT/$name.json" || true
  # gtest's JSON report: each test case has status/result and a "failures" list when it failed.
  # No report (the runner died or did nothing) counts as a failed suite.
  read -r p f k < <(python3 -I - "$OUT/$name.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print(0, 1, 0); sys.exit()
p = f = k = 0
for suite in d.get("testsuites", []):
    for t in suite.get("testsuite", []):
        if t.get("result") == "SKIPPED" or t.get("status") == "NOTRUN":
            k += 1
        elif t.get("failures"):
            f += 1
        else:
            p += 1
if p + f + k == 0:
    f = 1
print(p, f, k)
PY
)
  echo "$name: passed=$p failed=$f skipped=$k"
  passed=$((passed + p)); failed=$((failed + f)); skipped=$((skipped + k))
}

for s in basic parse sema; do gtest "unit-libnixf-$s" "$T/unit-libnixf-$s"; done
gtest unit-fork-piped "$T/test-fork-piped"

# regression/nixd (nixd/tools/meson.build): lit over nixd/tools/nixd/test, with the environment
# meson gives it — nixd on PATH, MESON_BUILD_ROOT as lit's exec root, NIXD_ATTRSET_EVAL. Every test
# runs `nixd --lit-test`, which sets the nixpkgs and NixOS-options expressions to `{ }`
# (nixd/lib/Controller/LifeTime.cpp). The tests listed below instead pass --nixpkgs-expr /
# --nixos-options-expr and check what the evaluator worker returns for them; this image has no nix
# evaluator (see mayhem/build.sh; mayhem/mock_attrset_eval.c answers every request with an error),
# so they are excluded by name, reason "no evaluator"; lit reports them as skipped.
NO_EVALUATOR=(
  completion/comment.md
  completion/dot.md
  completion/dot-select.md
  completion/nested.md
  completion/nixpkgs.md
  completion/options-attrs-of-submodule-body.md
  completion/options-default.md
  completion/options-default-only.md
  completion/options-incomplete.md
  completion/options-in-config.md
  completion/options.md
  completion/options-mid.md
  completion/options-no-snippet.md
  completion/options-snippet.md
  completion/option-stop.md
  completion/pkgs.md
  completion/resolve.md
  completion/select-empty-lib.md
  completion/select-empty-pkgs.md
  completion/select-lib.md
  completion/select.md
  completion/with-expr-select.md
  completion/with-select.md
  definition/options.md
  definition/package.md
  definition/select-package.md
  definition/select-package-with.md
  hover/empty-payload.md
  hover/options-in-config.md
  hover/options.md
  hover/package.md
  hover/package-select.md
  hover/value-docs.md
  inlay-hint.md
)
# format/format.md is excluded by name too, reason "nixfmt stub races SIGPIPE": its formatter stub
# (nixd/tools/nixd/test/format/nixfmt, `echo "Hello"`) exits without reading stdin, while
# nixd/lib/Controller/Format.cpp write(2)s the whole document to the stub's stdin before close/waitpid
# and nothing in nixd ignores SIGPIPE. Whether nixd dies with SIGPIPE (lit: -13) depends on whether the
# stub exits before the write, i.e. on scheduling, not on the code under test, so it fails at random.
SIGPIPE_RACE=(
  format/format.md
)
LIT="/usr/lib/llvm-19/build/utils/lit/lit.py"
FILECHECK_DIR="/usr/lib/llvm-19/bin"
LIT_SUITE="$SRC/nixd/tools/nixd/test"
if [ ! -x "$T/nixd" ] || [ ! -f "$LIT" ] || [ ! -x "$FILECHECK_DIR/FileCheck" ] || [ ! -x "$SRC/nixd-attrset-eval-mock" ]; then
  echo "missing nixd, lit, FileCheck or nixd-attrset-eval-mock — run mayhem/build.sh first" >&2
  failed=$((failed + 1))
else
  filter=""
  for t in "${NO_EVALUATOR[@]}"; do
    if [ -f "$LIT_SUITE/$t" ]; then
      echo "regression/nixd: skipped $t (no evaluator)"   # lit's xunit report counts it as skipped
    fi
    filter="${filter:+$filter|}${t//./\\.}"
  done
  for t in "${SIGPIPE_RACE[@]}"; do
    if [ -f "$LIT_SUITE/$t" ]; then
      echo "regression/nixd: skipped $t (nixfmt stub races SIGPIPE)"
    fi
    filter="${filter:+$filter|}${t//./\\.}"
  done
  mkdir -p "$OUT/lit-root"
  PATH="$T:$FILECHECK_DIR:$PATH" MESON_BUILD_ROOT="$OUT/lit-root" NIX_PATH="" \
  NIXD_ATTRSET_EVAL="$SRC/nixd-attrset-eval-mock" \
    python3 "$LIT" -v -j "$MAYHEM_JOBS" --filter-out ":: ($filter)\$" \
      --xunit-xml-output "$OUT/lit.xml" "$LIT_SUITE" || true
  read -r p f k < <(python3 -I - "$OUT/lit.xml" <<'PY'
import sys, xml.etree.ElementTree as ET
try:
    cases = list(ET.parse(sys.argv[1]).getroot().iter("testcase"))
except Exception:
    print(0, 1, 0); sys.exit()
p = f = k = 0
for c in cases:
    if c.find("failure") is not None or c.find("error") is not None:
        f += 1
    elif c.find("skipped") is not None:
        k += 1
    else:
        p += 1
if p + f + k == 0:
    f = 1
print(p, f, k)
PY
)
  echo "regression/nixd: passed=$p failed=$f skipped=$k"
  passed=$((passed + p)); failed=$((failed + f)); skipped=$((skipped + k))
fi

emit_ctrf "gtest+lit" "$passed" "$failed" "$skipped"
