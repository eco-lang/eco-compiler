// EcoBootConfig.cpp — runtime resolver for paths declared in
// EcoBootConfig.h (the CMake-generated header). See the header for the
// dual representation (basename + subdir + buildPath fallback) and
// plans/stage-c-bundle-runtime.md for the bundle layout.
//
// Linux-only: uses /proc/self/exe. Stage B is Linux x86_64 by design
// (see plans/static-link-eco-binary.md scope), so this is intentional.

#include "eco/EcoBootConfig.h"

#include <climits>
#include <cstdlib>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

namespace eco {
namespace config {

namespace {

// True iff path names an existing filesystem entry (file or directory).
bool exists(const std::string &path) {
    struct stat st;
    return ::stat(path.c_str(), &st) == 0;
}

// dirname of the running executable, via /proc/self/exe. Returns an empty
// string on readlink failure (no exe path, no error reporting — the
// resolver will then fall back to buildPath, which is the right behavior
// when running in a stripped-down environment).
std::string exeDir() {
    char buf[PATH_MAX];
    ssize_t n = ::readlink("/proc/self/exe", buf, sizeof(buf) - 1);
    if (n <= 0)
        return {};
    buf[n] = '\0';
    std::string exe(buf);
    auto pos = exe.find_last_of('/');
    return (pos == std::string::npos) ? std::string(".") : exe.substr(0, pos);
}

} // namespace

// runtimeDir(): where the bundle expects to find its lib/eco-runtime/ tree.
//
//   1. $ECO_RUNTIME_DIR if set (explicit override; trusted unconditionally).
//   2. Auto-resolved as dirname(realpath("/proc/self/exe")) + "/../lib/eco-runtime".
//      Used when the installed bundle layout is in effect.
//   3. Empty string if neither — resolveFile() then falls back to buildPath.
std::string runtimeDir() {
    if (const char *env = std::getenv("ECO_RUNTIME_DIR")) {
        return std::string(env);
    }
    std::string bin = exeDir();
    if (bin.empty())
        return {};
    return bin + "/../lib/eco-runtime";
}

// resolveFile(): pick the right path for a single RuntimeFile.
//
//   - If $ECO_RUNTIME_DIR is set, trust it: return dir/[subdir/]basename
//     even if the file doesn't exist (lets users debug missing-file
//     problems instead of silently falling back).
//   - Else if the auto-resolved bundle dir contains the file, use it.
//   - Else fall back to buildPath. This is what eco-boot-native sees
//     during the build (the bundle doesn't exist yet) and what any
//     stripped-down environment without /proc would see.
std::string resolveFile(const RuntimeFile &f) {
    auto join = [](const std::string &dir, const char *subdir, const char *base) {
        std::string p = dir;
        if (subdir && *subdir) {
            p += '/';
            p += subdir;
        }
        p += '/';
        p += base;
        return p;
    };

    if (const char *env = std::getenv("ECO_RUNTIME_DIR")) {
        return join(env, f.subdir, f.basename);
    }

    std::string bin = exeDir();
    if (!bin.empty()) {
        std::string autoPath = join(bin + "/../lib/eco-runtime", f.subdir, f.basename);
        if (exists(autoPath))
            return autoPath;
    }

    return f.buildPath ? std::string(f.buildPath) : std::string{};
}

// hasGlibcOutputProfile(): capability probe for the Stage D glibc
// output-profile inputs (lib/eco-runtime/glibc/). Unlike resolveFile(),
// which trusts $ECO_RUNTIME_DIR unconditionally, this stats the
// directory even under the env override — it answers "can this
// installation link .so/.node outputs at all", and the honest answer to
// that is on the filesystem. The env branch is what lets an interactive
// static-dev container exercise Stage D against an extracted
// glibc-runtime tree. See plans/stage-d-hybrid-link-profiles.md.
bool hasGlibcOutputProfile() {
    if (const char *env = std::getenv("ECO_RUNTIME_DIR"))
        return exists(std::string(env) + "/glibc");
    std::string bin = exeDir();
    if (bin.empty())
        return false;
    return exists(bin + "/../lib/eco-runtime/glibc");
}

} // namespace config
} // namespace eco
