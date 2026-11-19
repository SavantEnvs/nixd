// Stand-in for the nix C++ header <nix/expr/value.hh>, used only by the nixd fuzz build.
// nixd/include/nixd/Protocol/AttrSet.h includes it but uses no declaration from it (the only
// mention of nix::Value there is a comment); everything that does use the nix evaluator
// (nixd/lib/Eval/AttrSetProvider.cpp, libnixt, nixd-attrset-eval) is left out of this build because
// Debian ships the nix libraries without headers or a development package.
#pragma once
