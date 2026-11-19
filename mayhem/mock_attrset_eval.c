/*
 * Stand-in for nixd-attrset-eval, used only by the nixd_lsp_fuzzer harness.
 *
 * nixd forks nixd-attrset-eval workers (nixpkgs / NixOS options evaluators) and talks LSP-style
 * JSON-RPC to them over pipes. The real worker links the nix evaluator, which this image cannot
 * build (no nix C++ development package in Debian), and needs a nixpkgs checkout anyway. This
 * program answers every request with a JSON-RPC error, which is what nixd gets from a real worker
 * whose evaluation failed, so nixd's completion/hover/definition paths that wait for the worker
 * receive a reply and carry on. It reads "Content-Length:" framed messages on stdin until EOF.
 *
 * nixd serializes with llvm::json, which sorts object keys, so a request starts {"id":<n>,... and
 * the first "id": in the body is the top-level one; a message without "method" is a reply/no-op.
 * It exits on the "exit" notification, as the real worker does.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void) {
  char line[4096];
  for (;;) {
    long len = -1;
    for (;;) {
      if (!fgets(line, sizeof line, stdin))
        return 0;
      if (strncmp(line, "Content-Length:", 15) == 0)
        len = strtol(line + 15, NULL, 10);
      else if (line[0] == '\r' || line[0] == '\n')
        break;
    }
    if (len < 0 || len > (64L << 20))
      return 0;
    char *body = malloc((size_t)len + 1);
    if (!body || fread(body, 1, (size_t)len, stdin) != (size_t)len)
      return 0;
    body[len] = 0;
    /* Like the real worker, stop on the "exit" notification nixd sends when it tears down. */
    if (strstr(body, "\"method\":\"exit\""))
      return 0;
    const char *id = strstr(body, "\"id\":");
    if (id && strstr(body, "\"method\":")) {
      id += 5;
      size_t n = strcspn(id, ",}");
      char reply[512];
      int m = snprintf(reply, sizeof reply,
                       "{\"error\":{\"code\":-32603,\"message\":\"no nix evaluator in this build\"},"
                       "\"id\":%.*s,\"jsonrpc\":\"2.0\"}",
                       (int)(n < 64 ? n : 64), id);
      printf("Content-Length: %d\r\n\r\n%s", m, reply);
      fflush(stdout);
    }
    free(body);
  }
}
