//===- Spawn.cpp - start a child process without fork (POD only) ----------===//
//
// See Spawn.hpp. No heap access (G1/G3): the caller has already copied every
// input out of the heap.
//
// Templates used: none (POD only).
//
//===----------------------------------------------------------------------===//

#include "Spawn.hpp"

#include <cerrno>
#include <cstring>
#include <mutex>
#include <unordered_map>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <fcntl.h>
#include <io.h>
#include <algorithm>
#include <cwchar>
#include <iterator>
#else
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
extern char** environ;
#endif

namespace Elm::platform {

#if defined(_WIN32)

// ===========================================================================
// Windows: CreateProcessW
// ===========================================================================

namespace {

std::wstring widen(const std::string& s) {
    if (s.empty()) return std::wstring();
    const int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
    std::wstring w(static_cast<size_t>(n), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), w.data(), n);
    return w;
}

// One argument quoted so that CommandLineToArgvW (the MSVC CRT's rules) gives
// it back unchanged: backslashes are literal except before a double quote,
// where 2n backslashes + quote = n backslashes and an end of quoting, and
// 2n+1 backslashes + quote = n backslashes and a literal quote.
void appendQuoted(std::wstring& out, const std::wstring& arg) {
    if (!arg.empty() && arg.find_first_of(L" \t\n\v\"") == std::wstring::npos) {
        out += arg;
        return;
    }
    out += L'"';
    for (size_t i = 0;; ++i) {
        size_t backslashes = 0;
        while (i < arg.size() && arg[i] == L'\\') { ++i; ++backslashes; }
        if (i == arg.size()) {
            out.append(backslashes * 2, L'\\');   // before the closing quote
            break;
        }
        if (arg[i] == L'"') {
            out.append(backslashes * 2 + 1, L'\\');
            out += L'"';
        } else {
            out.append(backslashes, L'\\');
            out += arg[i];
        }
    }
    out += L'"';
}

std::wstring commandLine(const std::vector<std::wstring>& argv) {
    std::wstring line;
    for (size_t i = 0; i < argv.size(); ++i) {
        if (i) line += L' ';
        appendQuoted(line, argv[i]);
    }
    return line;
}

bool keyEquals(const std::wstring& a, const std::wstring& b) {
    return CompareStringOrdinal(a.data(), static_cast<int>(a.size()), b.data(),
                                static_cast<int>(b.size()), TRUE) == CSTR_EQUAL;
}

std::wstring keyOf(const std::wstring& kv) {
    // "=C:=C:\dir" style entries keep their leading '=' in the key.
    const size_t eq = kv.find(L'=', 1);
    return eq == std::wstring::npos ? kv : kv.substr(0, eq);
}

// The UTF-16 environment block: "K=V\0...K=V\0\0", sorted case-insensitively.
std::wstring environmentBlock(const SpawnSpec& spec) {
    std::vector<std::wstring> entries;
    if (spec.envMode != kEnvReplace) {
        if (wchar_t* block = GetEnvironmentStringsW()) {
            for (const wchar_t* p = block; *p; p += std::wcslen(p) + 1) entries.emplace_back(p);
            FreeEnvironmentStringsW(block);
        }
    }
    if (spec.envMode != kEnvInherit) {
        for (const auto& [k, v] : spec.env) {
            const std::wstring key = widen(k);
            std::wstring kv = key + L"=" + widen(v);
            bool replaced = false;
            for (auto& e : entries) {
                if (keyEquals(keyOf(e), key)) { e = kv; replaced = true; break; }
            }
            if (!replaced) entries.push_back(std::move(kv));
        }
    }
    std::sort(entries.begin(), entries.end(), [](const std::wstring& a, const std::wstring& b) {
        const std::wstring ka = keyOf(a), kb = keyOf(b);
        return CompareStringOrdinal(ka.data(), static_cast<int>(ka.size()), kb.data(),
                                    static_cast<int>(kb.size()), TRUE) == CSTR_LESS_THAN;
    });
    std::wstring block;
    for (const auto& e : entries) { block += e; block += L'\0'; }
    block += L'\0';
    if (entries.empty()) block += L'\0';
    return block;
}

// The program to run for NoShell: an explicit path as given, else PATH with
// PATHEXT's first match (SearchPathW tries ".exe" when the name has no
// extension). Empty when not found: CreateProcessW then searches itself.
std::wstring resolveProgram(const std::wstring& program) {
    if (program.find_first_of(L"\\/:") != std::wstring::npos) return program;
    wchar_t buf[MAX_PATH * 4];
    const DWORD n = SearchPathW(nullptr, program.c_str(), L".exe", static_cast<DWORD>(std::size(buf)), buf, nullptr);
    if (n > 0 && n < std::size(buf)) return std::wstring(buf, n);
    return std::wstring();
}

int errnoFromWin32(DWORD e) {
    switch (e) {
        case ERROR_FILE_NOT_FOUND:
        case ERROR_PATH_NOT_FOUND:
        case ERROR_BAD_PATHNAME:
        case ERROR_DIRECTORY: return ENOENT;
        case ERROR_ACCESS_DENIED: return EACCES;
        case ERROR_NOT_ENOUGH_MEMORY:
        case ERROR_OUTOFMEMORY: return ENOMEM;
        case ERROR_BAD_EXE_FORMAT: return ENOEXEC;
        default: return EIO;
    }
}

void closeH(HANDLE& h) {
    if (h && h != INVALID_HANDLE_VALUE) CloseHandle(h);
    h = nullptr;
}

// An inheritable duplicate of a standard handle (Inherit modes): the handle
// list may only name inheritable handles.
HANDLE inheritableCopy(DWORD which) {
    HANDLE src = GetStdHandle(which), dup = nullptr;
    if (!src || src == INVALID_HANDLE_VALUE) return nullptr;
    if (!DuplicateHandle(GetCurrentProcess(), src, GetCurrentProcess(), &dup, 0, TRUE, DUPLICATE_SAME_ACCESS))
        return nullptr;
    return dup;
}

std::mutex g_handlesMu;
std::unordered_map<int64_t, HANDLE> g_handles;

} // namespace

void registerProcessHandle(int64_t pid, void* process) {
    std::lock_guard<std::mutex> lk(g_handlesMu);
    g_handles[pid] = static_cast<HANDLE>(process);
}

void* takeProcessHandle(int64_t pid) {
    std::lock_guard<std::mutex> lk(g_handlesMu);
    auto it = g_handles.find(pid);
    if (it == g_handles.end()) return nullptr;
    HANDLE h = it->second;
    g_handles.erase(it);
    return h;
}

SpawnedChild spawnChild(const SpawnSpec& spec, StdioMode mode, bool newSession) {
    SpawnedChild c;

    // --- argv (Shell) ------------------------------------------------------
    std::vector<std::wstring> argv;
    std::wstring application;   // lpApplicationName, or empty
    if (spec.shellKind == kShellNone) {
        const std::wstring prog = widen(spec.program);
        application = resolveProgram(prog);
        argv.push_back(prog);
        for (const auto& a : spec.args) argv.push_back(widen(a));
    } else {
        std::string line = spec.program;
        for (const auto& a : spec.args) { line += ' '; line += a; }
        std::wstring shell;
        if (spec.shellKind == kShellCustom && !spec.customShell.empty()) {
            shell = widen(spec.customShell);
        } else {
            wchar_t comspec[MAX_PATH];
            const DWORD n = GetEnvironmentVariableW(L"ComSpec", comspec, MAX_PATH);
            shell = (n > 0 && n < MAX_PATH) ? std::wstring(comspec, n) : std::wstring(L"cmd.exe");
        }
        application = shell;
        argv.push_back(shell);
        argv.push_back(L"/d");
        argv.push_back(L"/s");
        argv.push_back(L"/c");
        argv.push_back(widen(line));
    }
    std::wstring cmd = commandLine(argv);
    std::wstring env = environmentBlock(spec);
    std::wstring cwd = spec.inheritCwd ? std::wstring() : widen(spec.cwd);

    // --- stdio -------------------------------------------------------------
    SECURITY_ATTRIBUTES sa{sizeof(SECURITY_ATTRIBUTES), nullptr, TRUE};
    HANDLE in = nullptr, out = nullptr, err = nullptr;           // the child's
    HANDLE inW = nullptr, outR = nullptr, errR = nullptr;        // the parent's
    auto fail = [&](DWORD e) {
        closeH(in); closeH(inW);
        if (out != err) closeH(err); closeH(out); closeH(outR); closeH(errR);
        c.err = errnoFromWin32(e);
        return c;
    };
    auto nullDevice = [&]() {
        return CreateFileW(L"NUL", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                           &sa, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    };
    auto pipe = [&](HANDLE& childEnd, HANDLE& parentEnd, bool childReads) -> bool {
        HANDLE r = nullptr, w = nullptr;
        if (!CreatePipe(&r, &w, &sa, 0)) return false;
        childEnd = childReads ? r : w;
        parentEnd = childReads ? w : r;
        SetHandleInformation(parentEnd, HANDLE_FLAG_INHERIT, 0);
        return true;
    };
    switch (mode) {
        case StdioMode::Inherit:
            in = inheritableCopy(STD_INPUT_HANDLE);
            out = inheritableCopy(STD_OUTPUT_HANDLE);
            err = inheritableCopy(STD_ERROR_HANDLE);
            break;
        case StdioMode::Pipes:
            if (!pipe(in, inW, true) || !pipe(out, outR, false) || !pipe(err, errR, false)) return fail(GetLastError());
            break;
        case StdioMode::Null:
            in = nullDevice();
            out = nullDevice();
            err = nullDevice();
            if (in == INVALID_HANDLE_VALUE || out == INVALID_HANDLE_VALUE || err == INVALID_HANDLE_VALUE)
                return fail(GetLastError());
            break;
        case StdioMode::RunPipes:
            in = nullDevice();
            if (in == INVALID_HANDLE_VALUE) return fail(GetLastError());
            if (!pipe(out, outR, false) || !pipe(err, errR, false)) return fail(GetLastError());
            break;
        case StdioMode::StdinPipe:
            if (!pipe(in, inW, true)) return fail(GetLastError());
            out = inheritableCopy(STD_OUTPUT_HANDLE);
            err = inheritableCopy(STD_ERROR_HANDLE);
            break;
        case StdioMode::ToFile:
            in = spec.inputPath.empty()
                ? nullDevice()
                : CreateFileW(widen(spec.inputPath).c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                              &sa, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
            if (in == INVALID_HANDLE_VALUE) { in = nullptr; return fail(GetLastError()); }
            out = CreateFileW(widen(spec.outputPath).c_str(), GENERIC_WRITE,
                              FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, &sa,
                              CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
            if (out == INVALID_HANDLE_VALUE) { out = nullptr; return fail(GetLastError()); }
            err = out;
            break;
    }

    // Exactly these handles are inherited (PROC_THREAD_ATTRIBUTE_HANDLE_LIST):
    // a plain bInheritHandles would hand every inheritable handle of the
    // parent to the child.
    std::vector<HANDLE> inherit;
    for (HANDLE h : {in, out, err}) {
        if (h && h != INVALID_HANDLE_VALUE && std::find(inherit.begin(), inherit.end(), h) == inherit.end())
            inherit.push_back(h);
    }
    SIZE_T attrSize = 0;
    InitializeProcThreadAttributeList(nullptr, 1, 0, &attrSize);
    std::vector<unsigned char> attrBuf(attrSize);
    auto* attrs = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(attrBuf.data());
    if (!InitializeProcThreadAttributeList(attrs, 1, 0, &attrSize)) return fail(GetLastError());
    if (!inherit.empty() &&
        !UpdateProcThreadAttribute(attrs, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, inherit.data(),
                                   inherit.size() * sizeof(HANDLE), nullptr, nullptr)) {
        const DWORD e = GetLastError();
        DeleteProcThreadAttributeList(attrs);
        return fail(e);
    }

    STARTUPINFOEXW si{};
    si.StartupInfo.cb = sizeof(si);
    si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    si.StartupInfo.hStdInput = in;
    si.StartupInfo.hStdOutput = out;
    si.StartupInfo.hStdError = err;
    si.lpAttributeList = attrs;

    // Suspended until it is in its Job, so it cannot start a grandchild
    // outside the Job first.
    DWORD flags = EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT | CREATE_SUSPENDED;
    if (newSession) flags |= CREATE_NEW_PROCESS_GROUP;
    PROCESS_INFORMATION pi{};
    const BOOL ok = CreateProcessW(application.empty() ? nullptr : application.c_str(), cmd.data(), nullptr,
                                   nullptr, inherit.empty() ? FALSE : TRUE, flags, env.data(),
                                   cwd.empty() ? nullptr : cwd.c_str(), &si.StartupInfo, &pi);
    const DWORD createErr = ok ? 0 : GetLastError();
    DeleteProcThreadAttributeList(attrs);
    if (!ok) return fail(createErr);

    if (spec.killTreeOnRelease) {
        HANDLE job = CreateJobObjectW(nullptr, nullptr);
        if (job) {
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION info{};
            info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            SetInformationJobObject(job, JobObjectExtendedLimitInformation, &info, sizeof(info));
            if (!AssignProcessToJobObject(job, pi.hProcess)) closeH(job);
        }
        c.job = job;
    }
    ResumeThread(pi.hThread);
    CloseHandle(pi.hThread);

    // The child's ends belong to the child now.
    closeH(in);
    if (err != out) closeH(err);
    closeH(out);
    c.pid = static_cast<int64_t>(pi.dwProcessId);
    c.process = pi.hProcess;
    if (inW) c.stdinFd = _open_osfhandle(reinterpret_cast<intptr_t>(inW), _O_WRONLY | _O_BINARY);
    if (outR) c.stdoutFd = _open_osfhandle(reinterpret_cast<intptr_t>(outR), _O_RDONLY | _O_BINARY);
    if (errR) c.stderrFd = _open_osfhandle(reinterpret_cast<intptr_t>(errR), _O_RDONLY | _O_BINARY);
    return c;
}

namespace {
ChildExit exitOf(HANDLE process) {
    ChildExit e;
    DWORD code = 0;
    GetExitCodeProcess(process, &code);
    // NTSTATUS error codes (0xC0000005 access violation, 0xC0000409 stack
    // buffer overrun, ...) are crashes, as a POSIX signal death is.
    if ((code & 0xF0000000u) == 0xC0000000u) {
        e.signaled = true;
        e.signal = static_cast<int>(code);
    } else {
        e.exited = true;
        e.code = static_cast<int>(code);
    }
    return e;
}
} // namespace

ChildState pollChild(SpawnedChild& child, ChildExit& out) {
    if (!child.process) return ChildState::Error;
    const DWORD r = WaitForSingleObject(static_cast<HANDLE>(child.process), 0);
    if (r == WAIT_TIMEOUT) return ChildState::Running;
    if (r != WAIT_OBJECT_0) return ChildState::Error;
    out = exitOf(static_cast<HANDLE>(child.process));
    return ChildState::Ended;
}

ChildExit waitChild(SpawnedChild& child) {
    if (!child.process) return ChildExit{};
    WaitForSingleObject(static_cast<HANDLE>(child.process), INFINITE);
    return exitOf(static_cast<HANDLE>(child.process));
}

void killChild(SpawnedChild& child) {
    if (child.job) TerminateJobObject(static_cast<HANDLE>(child.job), 1);
    else if (child.process) TerminateProcess(static_cast<HANDLE>(child.process), 1);
}

void releaseChild(SpawnedChild& child) {
    HANDLE p = static_cast<HANDLE>(child.process), j = static_cast<HANDLE>(child.job);
    closeH(p);
    closeH(j);
    child.process = nullptr;
    child.job = nullptr;
}

#else // POSIX

// ===========================================================================
// POSIX: posix_spawn / posix_spawnp
// ===========================================================================

namespace {

// The environment block for the child, as "K=V" strings.
std::vector<std::string> buildEnv(const SpawnSpec& spec) {
    std::vector<std::string> out;
    if (spec.envMode != kEnvReplace) {
        for (char** e = environ; e && *e; ++e) out.emplace_back(*e);
    }
    if (spec.envMode == kEnvInherit) return out;
    std::unordered_map<std::string, size_t> index;   // key -> position in out
    for (size_t i = 0; i < out.size(); ++i) {
        size_t eq = out[i].find('=');
        index.emplace(out[i].substr(0, eq), i);
    }
    for (const auto& [k, v] : spec.env) {
        std::string kv = k + "=" + v;
        auto it = index.find(k);
        if (it != index.end()) {
            out[it->second] = std::move(kv);
        } else {
            index.emplace(k, out.size());
            out.push_back(std::move(kv));
        }
    }
    return out;
}

std::vector<char*> cstrs(std::vector<std::string>& v) {
    std::vector<char*> out;
    out.reserve(v.size() + 1);
    for (auto& s : v) out.push_back(s.data());
    out.push_back(nullptr);
    return out;
}

void closeIf(int& fd) {
    if (fd >= 0) {
        ::close(fd);
        fd = -1;
    }
}

// A close-on-exec pipe (blocking ends).
int cloexecPipe(int fds[2]) {
#if defined(__linux__)
    if (::pipe2(fds, O_CLOEXEC) != 0) return errno;
    return 0;
#else
    if (::pipe(fds) != 0) return errno;
    for (int i = 0; i < 2; ++i) {
        if (::fcntl(fds[i], F_SETFD, FD_CLOEXEC) != 0) {
            const int e = errno;
            ::close(fds[0]);
            ::close(fds[1]);
            fds[0] = fds[1] = -1;
            return e;
        }
    }
    return 0;
#endif
}

// RAII for the posix_spawn attribute / file-action objects.
struct SpawnObjects {
    posix_spawn_file_actions_t fa;
    posix_spawnattr_t attr;
    bool faInit = false, attrInit = false;
    ~SpawnObjects() {
        if (faInit) posix_spawn_file_actions_destroy(&fa);
        if (attrInit) posix_spawnattr_destroy(&attr);
    }
};

ChildExit exitOf(int status) {
    ChildExit e;
    if (WIFEXITED(status)) {
        e.exited = true;
        e.code = WEXITSTATUS(status);
    } else if (WIFSIGNALED(status)) {
        e.signaled = true;
        e.signal = WTERMSIG(status);
    }
    return e;
}

} // namespace

SpawnedChild spawnChild(const SpawnSpec& spec, StdioMode mode, bool newSession) {
    SpawnedChild c;

    // --- argv and the file to execute (Shell) ------------------------------
    std::vector<std::string> argv;
    std::string file;
    bool searchPath = true;
    if (spec.shellKind == kShellNone) {
        file = spec.program;
        argv.push_back(spec.program);
        for (const auto& a : spec.args) argv.push_back(a);
    } else {
        std::string line = spec.program;
        for (const auto& a : spec.args) {
            line += ' ';
            line += a;
        }
        if (spec.shellKind == kShellCustom && !spec.customShell.empty()) {
            file = spec.customShell;
        } else {
            file = "/bin/sh";
            searchPath = false;
        }
        argv.push_back(file);
        argv.push_back("-c");
        argv.push_back(line);
    }

#if !defined(ECO_SPAWN_HAVE_ADDCHDIR_NP)
    if (!spec.inheritCwd) {
        // /bin/sh -c 'cd "$0" && exec "$@"' <cwd> <argv...>
        std::vector<std::string> wrapped{"/bin/sh", "-c", "cd \"$0\" && exec \"$@\"", spec.cwd};
        for (auto& a : argv) wrapped.push_back(std::move(a));
        argv = std::move(wrapped);
        file = "/bin/sh";
        searchPath = false;
    }
#endif

    std::vector<std::string> envStrs = buildEnv(spec);
    std::vector<char*> argvC = cstrs(argv);
    std::vector<char*> envC = cstrs(envStrs);

    // --- stdio -------------------------------------------------------------
    int inPipe[2] = {-1, -1}, outPipe[2] = {-1, -1}, errPipe[2] = {-1, -1};
    int devNull = -1, outFile = -1, inFile = -1;
    auto fail = [&](int e) {
        closeIf(inPipe[0]); closeIf(inPipe[1]);
        closeIf(outPipe[0]); closeIf(outPipe[1]);
        closeIf(errPipe[0]); closeIf(errPipe[1]);
        closeIf(devNull);
        closeIf(outFile);
        closeIf(inFile);
        c.err = e;
        return c;
    };
    if (mode == StdioMode::Pipes || mode == StdioMode::StdinPipe) {
        if (int e = cloexecPipe(inPipe)) return fail(e);
    }
    if (mode == StdioMode::Pipes || mode == StdioMode::RunPipes) {
        if (int e = cloexecPipe(outPipe)) return fail(e);
        if (int e = cloexecPipe(errPipe)) return fail(e);
    }
    if (mode == StdioMode::Null || mode == StdioMode::RunPipes || mode == StdioMode::ToFile) {
        devNull = ::open("/dev/null", O_RDWR | O_CLOEXEC);
        if (devNull < 0) return fail(errno);
    }
    if (mode == StdioMode::ToFile) {
        outFile = ::open(spec.outputPath.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
        if (outFile < 0) return fail(errno);
        if (!spec.inputPath.empty()) {
            inFile = ::open(spec.inputPath.c_str(), O_RDONLY | O_CLOEXEC);
            if (inFile < 0) return fail(errno);
        }
    }

    SpawnObjects so;
    if (int e = posix_spawn_file_actions_init(&so.fa)) return fail(e);
    so.faInit = true;
    if (int e = posix_spawnattr_init(&so.attr)) return fail(e);
    so.attrInit = true;

    int rc = 0;
    auto dup2Into = [&](int from, int to) {
        if (rc == 0) rc = posix_spawn_file_actions_adddup2(&so.fa, from, to);
    };
    auto inheritFd = [&](int fd) {
#if defined(__APPLE__)
        if (rc == 0) rc = posix_spawn_file_actions_addinherit_np(&so.fa, fd);
#else
        (void)fd;
#endif
    };
    switch (mode) {
        case StdioMode::Inherit:
            for (int fd = 0; fd <= 2; ++fd) inheritFd(fd);
            break;
        case StdioMode::Pipes:
            dup2Into(inPipe[0], 0);
            dup2Into(outPipe[1], 1);
            dup2Into(errPipe[1], 2);
            break;
        case StdioMode::Null:
            dup2Into(devNull, 0);
            dup2Into(devNull, 1);
            dup2Into(devNull, 2);
            break;
        case StdioMode::RunPipes:
            dup2Into(devNull, 0);
            dup2Into(outPipe[1], 1);
            dup2Into(errPipe[1], 2);
            break;
        case StdioMode::StdinPipe:
            dup2Into(inPipe[0], 0);
            inheritFd(1);
            inheritFd(2);
            break;
        case StdioMode::ToFile:
            dup2Into(inFile >= 0 ? inFile : devNull, 0);
            dup2Into(outFile, 1);
            dup2Into(outFile, 2);
            break;
    }
    if (rc) return fail(rc);

#if defined(ECO_SPAWN_HAVE_ADDCHDIR_NP)
    if (!spec.inheritCwd) {
        if (int e = posix_spawn_file_actions_addchdir_np(&so.fa, spec.cwd.c_str())) return fail(e);
    }
#endif

    short flags = 0;
#if defined(__APPLE__)
    flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
    // The child starts with default signal dispositions for the signals we
    // may be catching (a caught signal is reset by exec anyway; SIG_IGN of
    // SIGPIPE, set by eco_entry, would be inherited).
    sigset_t defaults;
    sigemptyset(&defaults);
    sigaddset(&defaults, SIGPIPE);
    sigaddset(&defaults, SIGINT);
    sigaddset(&defaults, SIGTERM);
    sigaddset(&defaults, SIGWINCH);
    if (int e = posix_spawnattr_setsigdefault(&so.attr, &defaults)) return fail(e);
    flags |= POSIX_SPAWN_SETSIGDEF;
    // Nor does it inherit the calling thread's signal mask.
    sigset_t noMask;
    sigemptyset(&noMask);
    if (int e = posix_spawnattr_setsigmask(&so.attr, &noMask)) return fail(e);
    flags |= POSIX_SPAWN_SETSIGMASK;
    if (newSession) {
#if defined(POSIX_SPAWN_SETSID)
        flags |= POSIX_SPAWN_SETSID;
#else
        if (int e = posix_spawnattr_setpgroup(&so.attr, 0)) return fail(e);
        flags |= POSIX_SPAWN_SETPGROUP;
#endif
    }
    if (int e = posix_spawnattr_setflags(&so.attr, flags)) return fail(e);

    pid_t pid = -1;
    int e = searchPath
        ? posix_spawnp(&pid, file.c_str(), &so.fa, &so.attr, argvC.data(), envC.data())
        : posix_spawn(&pid, file.c_str(), &so.fa, &so.attr, argvC.data(), envC.data());
    if (e != 0) return fail(e);

    // The child's ends belong to the child now.
    closeIf(inPipe[0]);
    closeIf(outPipe[1]);
    closeIf(errPipe[1]);
    closeIf(devNull);
    closeIf(outFile);
    closeIf(inFile);
    c.pid = pid;
    c.stdinFd = inPipe[1];
    c.stdoutFd = outPipe[0];
    c.stderrFd = errPipe[0];
    return c;
}

ChildState pollChild(SpawnedChild& child, ChildExit& out) {
    if (child.pid <= 0) return ChildState::Error;
    int status = 0;
    pid_t r;
    do {
        r = ::waitpid(static_cast<pid_t>(child.pid), &status, WNOHANG);
    } while (r < 0 && errno == EINTR);
    if (r == 0) return ChildState::Running;
    if (r < 0) return ChildState::Error;
    out = exitOf(status);
    return ChildState::Ended;
}

ChildExit waitChild(SpawnedChild& child) {
    if (child.pid <= 0) return ChildExit{};
    int status = 0;
    pid_t r;
    do {
        r = ::waitpid(static_cast<pid_t>(child.pid), &status, 0);
    } while (r < 0 && errno == EINTR);
    if (r < 0) return ChildExit{};
    return exitOf(status);
}

void killChild(SpawnedChild& child) {
    if (child.pid > 0) ::kill(static_cast<pid_t>(child.pid), SIGKILL);
}

void releaseChild(SpawnedChild& child) {
    child.process = nullptr;
    child.job = nullptr;
}

#endif // _WIN32

} // namespace Elm::platform
