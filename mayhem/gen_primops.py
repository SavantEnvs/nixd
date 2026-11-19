#!/usr/bin/env python3
"""Generate libnixf's PrimOpsInfo.cpp from the nix binary in the image, without the nix C++ libs.

Upstream generates this file with libnixf/src/Basic/PrimOpsInfoGen.cpp, which links nix-expr and
prints every nix::RegisterPrimOp entry (name, args, arity, doc, internal). Debian ships nix only as
binaries (nix-bin, no headers or libraries to link), so we derive the same table from the
evaluator itself:
  * `nix __dump-language` gives args and doc of every documented builtin (names without "__");
  * evaluating each bare name tells whether nix registers it globally ("map") or only with the
    "__" prefix ("__add"), which is how RegisterPrimOp names them;
  * primops in `builtins` that have no documentation are the ones upstream marks internal.
Constants (true, null, builtins, nixPath, ...) are not primops and are skipped, as upstream does.
Everything runs offline against the dummy:// store.

usage: gen_primops.py OUT.cpp
"""
import json
import os
import subprocess
import sys

XP = "nix-command flakes fetch-closure dynamic-derivations"
BASE = ["--store", "dummy://", "--option", "experimental-features", XP]
ENV = dict(os.environ, NIX_CONF_DIR="/nonexistent")


def nix(*args, check=True):
    # `nix __dump-language` is special-cased by nix's main() and takes no further arguments.
    argv = list(args) if args[0] == "nix" else [args[0]] + BASE + list(args[1:])
    r = subprocess.run(argv, env=ENV,
                       capture_output=True, text=True)
    if check and r.returncode != 0:
        sys.exit("gen_primops: %s failed:\n%s" % (" ".join(args), r.stderr))
    return r


def main():
    out = sys.argv[1]
    lang = json.loads(nix("nix", "__dump-language").stdout)
    names = json.loads(nix("nix-instantiate", "--eval", "--json", "--strict", "-E",
                           "builtins.attrNames builtins").stdout)

    prims = {}
    for name, info in lang.items():
        if "type" in info:  # a constant, not a primop
            continue
        # nix's createBaseEnv adds traceVerbose itself (not through RegisterPrimOp), so upstream's
        # generator never sees it; libnixf lists it among its Constants instead.
        if name == "traceVerbose":
            continue
        prims[name] = (info.get("args", []), info.get("doc", ""), False)
    for name in names:
        # `derivation` is a Nix-language lambda (nix's derivation.nix), not a registered primop.
        if name in prims or name in lang or name == "derivation":
            continue
        typ = nix("nix-instantiate", "--eval", "--json", "-E",
                  "builtins.typeOf builtins.%s" % name, check=False).stdout.strip()
        if typ == '"lambda"':
            prims[name] = ([], "", True)

    # One evaluation per name: does the bare identifier resolve at top level?
    globals_ = set()
    for name in prims:
        expr = "builtins.seq (%s) true" % name
        r = nix("nix-instantiate", "--eval", "-E", expr, check=False)
        if r.returncode == 0:
            globals_.add(name)

    def q(s):
        return s.replace("\\", "\\\\").replace('"', '\\"')

    with open(out + ".tmp", "w") as f:
        f.write("#include <nixf/Sema/PrimOpInfo.h>\n\n")
        f.write("std::map<std::string, nixf::PrimOpInfo> nixf::PrimOpsInfo = {\n")
        for name in sorted(prims):
            args, doc, internal = prims[name]
            full = name if name in globals_ else "__" + name
            f.write('  {"%s", {\n' % q(full))
            f.write("    .Args = {%s},\n" % ", ".join('"%s"' % q(a) for a in args))
            f.write("    .Arity = %d,\n" % len(args))
            f.write('    .Doc = R"xabc(%s)xabc",\n' % doc)
            f.write("    .Internal = %s,\n" % ("true" if internal else "false"))
            f.write("  }},\n")
        f.write("};\n")
    os.replace(out + ".tmp", out)
    print("gen_primops: %d primops (%d global)" % (len(prims), len(globals_)))


if __name__ == "__main__":
    main()
