// EcoBootConfig.cpp - finds the files the compiler links into its output.
//
// A compiled program is linked against runtime archives, kernel libraries and
// C runtime objects. The build generates `eco/EcoBootConfig.h`, which names
// each such file as a `RuntimeFile`: a basename, a subdirectory and the path
// the file has in the build tree (`buildPath`). The build-tree path holds only
// on the machine that did the build, so where a file is actually found is
// decided here, at run time.
//
// An installation is a directory tree with the running executable in one
// directory and the files in `lib/eco-runtime` beside it, that is at
// `<executable directory>/../lib/eco-runtime/<subdir>/<basename>`. The
// environment variable `ECO_RUNTIME_DIR`, when set, names that
// `lib/eco-runtime` directory explicitly and takes precedence. When it is not
// set and the file is not in the installation, `buildPath` is used.
//
// The generated header declares the three functions defined here and is not
// written by hand, so their contracts are stated on these definitions.

#include "eco/EcoBootConfig.h"
#include "../platform/PlatformPaths.hpp"

#include <cstdlib>
#include <filesystem>
#include <string>

namespace eco {
namespace config {

namespace {

// Returns whether `path` names an existing file or directory. A path that
// cannot be checked counts as absent.
bool exists(const std::string &path) {
    std::error_code ec;
    return std::filesystem::exists(path, ec);
}

// Returns the directory holding the running executable, as
// `eco::platform::currentExecutableDir` gives it, or an empty string when it
// cannot be determined or the executable is directly under "/".
std::string exeDir() {
    return eco::platform::currentExecutableDir();
}

} // namespace

// Returns the `lib/eco-runtime` directory of the installation: the value of
// `ECO_RUNTIME_DIR` if it is set, otherwise `<executable directory>/../lib/
// eco-runtime`, otherwise, when `exeDir` returns an empty string, an empty
// string. Neither directory is checked to exist.
std::string runtimeDir() {
    if (const char *env = std::getenv("ECO_RUNTIME_DIR")) {
        return std::string(env);
    }
    std::string bin = exeDir();
    if (bin.empty())
        return {};
    return bin + "/../lib/eco-runtime";
}

// Returns the path at which to find `f`.
//
// If `ECO_RUNTIME_DIR` is set, the result is `<that directory>/<subdir>/
// <basename>` (without `<subdir>/` when the subdirectory is empty), whether or
// not the file exists there. Otherwise it is the same path under the
// installation beside the executable, if a file or directory exists there.
// Otherwise it is `f.buildPath`, which is not checked either, or an empty
// string if `buildPath` is null.
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

// Returns whether the installation has an entry named `glibc`, the directory
// that holds the inputs for linking against glibc: `<ECO_RUNTIME_DIR>/glibc`
// if that variable is set, otherwise
// `<executable directory>/../lib/eco-runtime/glibc`. Unlike `resolveFile`,
// this checks that the directory exists even when `ECO_RUNTIME_DIR` is set,
// and it never falls back to the build tree. It returns false when that
// variable is not set and `exeDir` returns an empty string. Only the directory
// is checked, not the files in it.
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
