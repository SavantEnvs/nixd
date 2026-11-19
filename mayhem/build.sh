#!/usr/bin/env bash
#
# mayhem/build.sh — build nixd's fuzz harnesses and libnixf's unit tests.
#
# Upstream builds with meson, but its top-level meson.build (and libnixf/meson.build) require the nix
# C++ libraries (nix-expr/nix-main/nix-cmd/nix-flake via pkg-config), which Debian does not ship:
# nix-bin has the binaries only. Everything the harnesses reach does not need them, so this script
# compiles the same source lists meson uses (libnixf/src/meson.build, nixd/lspserver/meson.build,
# nixd/lib/meson.build) directly, leaving out only the nix-linked parts:
#   * libnixf's PrimOpsInfo.cpp is generated from the nix binary (mayhem/gen_primops.py) instead of
#     by PrimOpsInfoGen.cpp linked against nix-expr;
#   * nixd/lib/Eval/AttrSetProvider.cpp (the evaluator side, run in the separate nixd-attrset-eval
#     process) and libnixt are not built; mayhem/stub/nix/expr/value.hh stands in for the one nix
#     header nixd/include/nixd/Protocol/AttrSet.h includes without using.
# Building the nix libraries from source under /opt/toolchains/deps/ instead is not done: nixd pins
# nix 2.34 (flake.nix nixComponents_2_34) while Debian 13 ships 2.26, and nix 2.34's own meson build
# needs a dependency closure (boehm-gc, libgit2, curl, sqlite, libarchive, brotli, libsodium, blake3,
# toml11, boost, editline, libseccomp, ...) of which blake3 has no Debian package at all. What that
# leaves unfuzzed is the evaluator side, which runs in the separate nixd-attrset-eval process on
# trusted nixpkgs/option expressions; mayhem/mock_attrset_eval.c stands in for it.
# Generated sources and objects go to mayhem/build/ (gitignored); re-running rebuilds everything.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
B="$SRC/mayhem/build"
GEN="$B/gen"
rm -rf "$B"
mkdir -p "$GEN"

# llvm-config by name (SPEC §6.2 item 17); Debian names it llvm-config-19, `llvm-config` is its alternative.
LLVM_CONFIG="$(command -v llvm-config-19 || command -v llvm-config)"
LLVM_CXXFLAGS="-I$("$LLVM_CONFIG" --includedir)"
LLVM_LIBS="-L$("$LLVM_CONFIG" --libdir) $("$LLVM_CONFIG" --libs support --link-static) $("$LLVM_CONFIG" --system-libs --link-static)"

# 1) Generated sources (libnixf/src/meson.build custom_targets).
python3 libnixf/src/Basic/DiagnosticEnum.h.py "$GEN/DiagnosticEnum.h"
python3 libnixf/src/Basic/Diagnostic.cpp.py   "$GEN/Diagnostic.cpp"
python3 libnixf/src/Parse/Tokens.h.py         "$GEN/Tokens.h"
python3 libnixf/src/Parse/TokenKinds.inc.py   "$GEN/TokenKinds.inc"
python3 -I mayhem/gen_primops.py                 "$GEN/PrimOpsInfo.cpp"
cat > "$GEN/nixd-config.h" <<'H'
#pragma once
#define NIXD_VERSION "nightly"
#define NIXD_LIBEXEC "/usr/local/libexec"
H

NIXF_SRCS=(
  libnixf/src/Basic/Nodes.cpp libnixf/src/Basic/JSONDiagnostic.cpp libnixf/src/Basic/Diagnostic.cpp "$GEN/Diagnostic.cpp"
  libnixf/src/Parse/Lexer.cpp libnixf/src/Parse/ParseAttrs.cpp libnixf/src/Parse/ParseExpr.cpp
  libnixf/src/Parse/ParseLambda.cpp libnixf/src/Parse/ParseOp.cpp libnixf/src/Parse/ParseSimple.cpp
  libnixf/src/Parse/ParseStrings.cpp libnixf/src/Parse/ParseSupport.cpp
  libnixf/src/Sema/ParentMap.cpp libnixf/src/Sema/PrimOpLookup.cpp libnixf/src/Sema/SemaActions.cpp
  libnixf/src/Sema/VariableLookup.cpp "$GEN/PrimOpsInfo.cpp"
)
LSP_SRCS=(nixd/lspserver/src/{Connection,DraftStore,LSPServer,Logger,Protocol,SourceCode,URI}.cpp)
NIXD_SRCS=()
while read -r f; do
  [ "$f" = "Eval/AttrSetProvider.cpp" ] && continue
  NIXD_SRCS+=("nixd/lib/$f")
done < <(sed -n "s/^ *'\([A-Za-z/]*\.cpp\)',\$/\1/p" nixd/lib/meson.build)
[ "${#NIXD_SRCS[@]}" -gt 40 ] || { echo "parsed only ${#NIXD_SRCS[@]} nixd/lib sources" >&2; exit 1; }

NIXF_INC="-Ilibnixf/include -Ilibnixf/src -I$GEN"
CXXSTD="-std=gnu++20 -Wno-unused-parameter -Wno-missing-field-initializers"

# compile <objdir> <flags> <sources...>: objects into <objdir>, in parallel, fail on any error.
compile() {
  local out="$1" flags="$2"; shift 2
  mkdir -p "$out"
  printf '%s\n' "$@" | xargs -P "$MAYHEM_JOBS" -I{} sh -c \
    'o="$0/$(echo "{}" | sed "s|^$1/||; s|[/.]|_|g").o"; '"$CXX"' $2 -c "{}" -o "$o"' \
    "$out" "$B" "$flags"
}

# 2) Sanitized, instrumented project objects for the fuzz harnesses.
FUZZ="$SANITIZER_FLAGS $DEBUG_FLAGS -O1 -fsanitize=fuzzer-no-link $CXXSTD"
compile "$B/fuzz/nixf" "$FUZZ $NIXF_INC" "${NIXF_SRCS[@]}"
compile "$B/fuzz/lsp"  "$FUZZ $LLVM_CXXFLAGS -Inixd/lspserver/include" "${LSP_SRCS[@]}"
compile "$B/fuzz/nixd" "$FUZZ $LLVM_CXXFLAGS $NIXF_INC -Inixd/lspserver/include -Inixd/include -Inixd/lib -Imayhem/stub" "${NIXD_SRCS[@]}"

$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o "$B/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$B/standalone_main.o"

# link <name> <harness> <compile flags> <objects/libs...>
link() {
  local name="$1" src="$2" flags="$3"; shift 3
  $CXX $FUZZ $flags -c "$src" -o "$B/$name.o"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$B/$name.o" "$@" "$B/lsan_off.o" -o "$SRC/$name"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS "$B/standalone_main.o" "$B/$name.o" "$@" "$B/lsan_off.o" -o "$SRC/$name-standalone"
}

link nixf_parse_fuzzer mayhem/nixf_parse_fuzzer.cpp "$NIXF_INC" "$B"/fuzz/nixf/*.o
link nixd_lsp_fuzzer mayhem/nixd_lsp_fuzzer.cpp \
  "$LLVM_CXXFLAGS $NIXF_INC -Inixd/lspserver/include -Inixd/include -Imayhem/stub" \
  "$B"/fuzz/nixd/*.o "$B"/fuzz/lsp/*.o "$B"/fuzz/nixf/*.o $LLVM_LIBS -lpthread

# The nixd-attrset-eval stand-in the LSP harness points nixd at (see mayhem/mock_attrset_eval.c).
$CC -O1 $DEBUG_FLAGS mayhem/mock_attrset_eval.c -o "$SRC/nixd-attrset-eval-mock"

# 3) libnixf's own gtest suites (libnixf/test/meson.build), NORMAL flags, for mayhem/test.sh.
TEST="-O1 $CXXSTD $COVERAGE_FLAGS"
compile "$B/test/nixf" "$TEST $NIXF_INC" "${NIXF_SRCS[@]}"
mkdir -p "$B/tests"
$CXX $TEST $NIXF_INC libnixf/test/Basic/{Diagnostic,Nodes}.cpp "$B"/test/nixf/*.o \
  -lgtest_main -lgtest -lpthread -o "$B/tests/unit-libnixf-basic"
$CXX $TEST $NIXF_INC -Ilibnixf/src/Parse libnixf/test/Parse/{Lexer,ParseAttrs,ParseExpr,ParseLambda,ParseOp,ParseSimple}.cpp \
  "$B"/test/nixf/*.o -lgtest_main -lgtest -lpthread -o "$B/tests/unit-libnixf-parse"
$CXX $TEST $NIXF_INC -Ilibnixf/src/Sema libnixf/test/Sema/{SemaActions,VariableLookup}.cpp \
  "$B"/test/nixf/*.o -lgtest_main -lgtest -lpthread -o "$B/tests/unit-libnixf-sema"

# 4) nixd's own tests (nixd/tools/meson.build regression/nixd, nixd/test/meson.build unit/fork-piped),
#    NORMAL flags: the nixd server (nixd/tools/nixd.cpp over lspserver + nixd/lib) that the lit suite
#    drives, and the ForkPiped gtest.
compile "$B/test/lsp"  "$TEST $LLVM_CXXFLAGS -Inixd/lspserver/include" "${LSP_SRCS[@]}"
compile "$B/test/nixd" "$TEST $LLVM_CXXFLAGS $NIXF_INC -Inixd/lspserver/include -Inixd/include -Inixd/lib -Imayhem/stub" "${NIXD_SRCS[@]}"
$CXX $TEST $LLVM_CXXFLAGS $NIXF_INC -Inixd/lspserver/include -Inixd/include -Imayhem/stub nixd/tools/nixd.cpp \
  "$B"/test/nixd/*.o "$B"/test/lsp/*.o "$B"/test/nixf/*.o $LLVM_LIBS -lpthread -o "$B/tests/nixd"
$CXX $TEST -Inixd/include nixd/test/ForkPiped.cpp nixd/lib/Support/ForkPiped.cpp \
  -lgtest_main -lgtest -lpthread -o "$B/tests/test-fork-piped"

echo "build.sh: built $SRC/nixf_parse_fuzzer $SRC/nixd_lsp_fuzzer and $B/tests/*"
