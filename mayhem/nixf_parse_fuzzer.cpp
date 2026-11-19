// libFuzzer harness for libnixf: Nix source text -> parse -> semantic analysis -> JSON diagnostics.
// This is exactly what upstream's nixf-tidy (libnixf/tools/nixf-tidy.cpp) does with
// --variable-lookup on its stdin, plus the ParentMap analysis the language server runs on every
// opened document. No state survives between inputs: every object is local to one call.
#include "nixf/Basic/JSONDiagnostic.h"
#include "nixf/Basic/Nodes/Basic.h"
#include "nixf/Parse/Parser.h"
#include "nixf/Sema/ParentMap.h"
#include "nixf/Sema/VariableLookup.h"

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *Data, size_t Size) {
  // nixf-tidy reads the whole of stdin into a std::string and parses it.
  std::string Src(reinterpret_cast<const char *>(Data), Size);

  std::vector<nixf::Diagnostic> Diags;
  std::shared_ptr<nixf::Node> AST = nixf::parse(Src, Diags);

  if (AST) {
    nixf::VariableLookupAnalysis V(Diags);
    V.runOnAST(*AST);
    nixf::ParentMapAnalysis PM;
    PM.runOnAST(*AST);
  }

  nlohmann::json J;
  to_json(J, Diags);
  // nixf-tidy prints this with operator<<, i.e. dump() in strict UTF-8 mode, which throws
  // nlohmann::type_error (and so aborts nixf-tidy) as soon as a diagnostic quotes a non-UTF-8 byte
  // from the source. That would make every input with such a byte the same crash and hide the
  // parser, so serialize with invalid bytes replaced instead.
  (void)J.dump(-1, ' ', false, nlohmann::json::error_handler_t::replace);
  return 0;
}
