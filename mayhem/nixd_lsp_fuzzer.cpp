// libFuzzer harness for the nixd language server: the input is the byte stream a client writes to
// nixd's stdin (LSP JSON-RPC with "Content-Length:" framing, JSONStreamStyle::Standard), fed to the
// same lspserver::InboundPort + nixd::Controller pair that nixd/tools/nixd.cpp's main() builds.
//
// Per input: the bytes go into a fresh memfd (InboundPort polls and read(2)s a file descriptor;
// a memfd reads to EOF like a regular file, so every byte is delivered), a fresh Controller runs
// until EOF or an "exit" notification, and its destructor joins the request thread pool. Replies go
// to a null stream. Then every child process the input made nixd fork (the attrset-eval workers
// started on "initialize", nixfmt) is reaped: nixd itself never waitpid()s its workers (harmless for
// one long-lived server), so without this each input would leave zombies behind until fork() fails
// with EAGAIN in a later, unrelated input. Destroying the Controller closes the pipes to the
// workers, the mock sees EOF and exits, so the blocking wait ends. Only the children that appeared
// during this input are waited for (a /proc snapshot taken before it): the fuzzer process has
// children of its own, such as the sanitizer's long-lived llvm-symbolizer, that waitpid(-1) would
// block on forever. After that nothing the input can change survives the call.
//
// Environment (set once, read-only afterwards): nixd forks helper processes. On "initialize" it
// starts nixd-attrset-eval workers (path from $NIXD_ATTRSET_EVAL), and textDocument/formatting
// runs `nixfmt` from $PATH. Those are separate programs nixd talks to over pipes, not code under
// test, and the evaluator needs the nix C++ libraries this image does not have. The workers are
// mayhem/mock_attrset_eval.c (built next to this binary), which answers every request with an
// error the way a real worker with a failed evaluation does, so requests that wait on it complete;
// nixfmt is /bin/cat, an identity formatter.
#include "lspserver/Connection.h"
#include "lspserver/Logger.h"
#include "nixd/Controller/Controller.h"

#include <llvm/Support/raw_ostream.h>

#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <memory>
#include <string>
#include <cstring>
#include <cerrno>
#include <cstdio>
#include <dirent.h>
#include <set>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

namespace {
std::string MockBinDir;

// PIDs of this process's children, zombies included (field 4 of /proc/<pid>/stat is the ppid).
std::set<pid_t> childPids() {
  std::set<pid_t> Kids;
  const pid_t Self = getpid();
  DIR *D = opendir("/proc");
  if (!D)
    abort();
  while (dirent *E = readdir(D)) {
    char *End;
    long Pid = strtol(E->d_name, &End, 10);
    if (*End || Pid <= 0)
      continue;
    char Path[64], Buf[512];
    snprintf(Path, sizeof(Path), "/proc/%ld/stat", Pid);
    FILE *F = fopen(Path, "re");
    if (!F)
      continue; // already gone
    size_t N = fread(Buf, 1, sizeof(Buf) - 1, F);
    fclose(F);
    Buf[N] = 0;
    const char *P = strrchr(Buf, ')'); // comm may contain spaces and parens
    char State;
    long PPid;
    if (P && sscanf(P + 1, " %c %ld", &State, &PPid) == 2 && PPid == Self)
      Kids.insert(static_cast<pid_t>(Pid));
  }
  closedir(D);
  return Kids;
}
} // namespace

extern "C" int LLVMFuzzerInitialize(int *, char ***) {
  // The mock worker sits next to this executable (build.sh installs both into /mayhem).
  char Self[4096];
  ssize_t N = readlink("/proc/self/exe", Self, sizeof(Self) - 1);
  if (N <= 0)
    abort();
  std::string Exe(Self, static_cast<size_t>(N));
  std::string Mock = Exe.substr(0, Exe.rfind('/') + 1) + "nixd-attrset-eval-mock";
  if (access(Mock.c_str(), X_OK) != 0)
    abort();
  setenv("NIXD_ATTRSET_EVAL", Mock.c_str(), 1);
  // A private PATH dir holding nixfmt -> /bin/cat (identity formatter), ahead of the system PATH.
  const char *Tmp = getenv("TMPDIR");
  std::string Template = std::string(Tmp && *Tmp ? Tmp : "/tmp") + "/nixd-fuzz-bin-XXXXXX";
  if (char *Dir = mkdtemp(Template.data())) {
    MockBinDir = Dir;
    std::string Link = MockBinDir + "/nixfmt";
    (void)symlink("/bin/cat", Link.c_str());
    const char *Path = getenv("PATH");
    std::string NewPath = MockBinDir + ":" + (Path ? Path : "/usr/bin:/bin");
    setenv("PATH", NewPath.c_str(), 1);
  }
  return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *Data, size_t Size) {
  int FD = memfd_create("nixd-lsp-input", MFD_CLOEXEC);
  if (FD < 0)
    abort();
  for (size_t Off = 0; Off < Size;) {
    ssize_t W = write(FD, Data + Off, Size - Off);
    if (W <= 0)
      abort();
    Off += static_cast<size_t>(W);
  }
  if (lseek(FD, 0, SEEK_SET) != 0)
    abort();

  const std::set<pid_t> Before = childPids();
  {
    llvm::raw_null_ostream Logs;
    lspserver::StreamLogger Logger(Logs, lspserver::Logger::Level::Error);
    lspserver::LoggingSession Session(Logger);

    llvm::raw_null_ostream Sink;
    auto In = std::make_unique<lspserver::InboundPort>(
        FD, lspserver::JSONStreamStyle::Standard);
    auto Out = std::make_unique<lspserver::OutboundPort>(Sink, false);
    auto C = std::make_unique<nixd::Controller>(std::move(In), std::move(Out));
    C->run();
    C.reset(); // joins the worker pool before the streams it writes to go away
  }
  // Reap the children this input made nixd fork (see the header comment).
  for (pid_t Pid : childPids())
    if (!Before.count(Pid))
      while (waitpid(Pid, nullptr, 0) < 0 && errno == EINTR) {
      }
  close(FD);
  return 0;
}
