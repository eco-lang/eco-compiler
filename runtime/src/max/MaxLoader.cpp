/// \file MaxLoader.cpp
/// See MaxLoader.hpp.
#include "MaxLoader.hpp"

#include <dlfcn.h>

#include <cstdlib>
#include <mutex>

namespace eco::max {
namespace {

#if defined(__APPLE__)
constexpr const char *kLibraryName = "libmax.dylib";
#else
constexpr const char *kLibraryName = "libmax.so";
#endif

/// setenv without overwriting a value the user chose.
void setDefault(const char *name, const std::string &value) { ::setenv(name, value.c_str(), 0); }

void prepareEnvironment(const std::filesystem::path &root) {
    setDefault("MODULAR_MAX_PACKAGE_ROOT", root.string());
    setDefault("MODULAR_MOJO_MAX_PACKAGE_ROOT", root.string());
    setDefault("MODULAR_MOJO_MAX_IMPORT_PATH", (root / "lib" / "mojo").string());
    setDefault("MODULAR_TELEMETRY_ENABLED", "0");
    // MAX reads its workers' spin time from two variables and aborts when they disagree.
    const char *a = std::getenv("MODULAR_THREAD_BUSY_WAIT_US");
    const char *b = std::getenv("MODULAR_RUNTIME_THREAD_BUSY_WAIT_TIME_US");
    if (a && !b)
        ::setenv("MODULAR_RUNTIME_THREAD_BUSY_WAIT_TIME_US", a, 1);
    else if (b && !a)
        ::setenv("MODULAR_THREAD_BUSY_WAIT_US", b, 1);
}

const Api *loadOnce(const LoadOptions &options, std::string &error) {
    if (options.packageRoot.empty()) {
        error = "MAX: no package root given (the `modular` directory of the installed max wheel)";
        return nullptr;
    }
    const std::filesystem::path lib = options.packageRoot / "lib" / kLibraryName;
    std::error_code ec;
    if (!std::filesystem::exists(lib, ec)) {
        error = "MAX: " + lib.string() + " does not exist; is the max wheel installed?";
        return nullptr;
    }
    prepareEnvironment(options.packageRoot);

    // RTLD_LOCAL: libmax's own symbols (it carries its own LLVM) stay out of the global namespace.
    void *handle = ::dlopen(lib.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        const char *why = ::dlerror();
        error = "MAX: cannot load " + lib.string() + ": " + (why ? why : "unknown error");
        return nullptr;
    }

    static Api api;
    std::string missing;
#define ECO_MAX_RESOLVE(name)                                                                     \
    api.name = reinterpret_cast<decltype(api.name)>(::dlsym(handle, #name));                      \
    if (!api.name)                                                                                \
        missing += (missing.empty() ? "" : ", ") + std::string(#name);
    ECO_MAX_FUNCTIONS(ECO_MAX_RESOLVE)
#undef ECO_MAX_RESOLVE
    if (!missing.empty()) {
        error = "MAX: " + lib.string() + " lacks " + missing;
        return nullptr; // the handle stays open: unloading MAX is not supported
    }

    const char *version = api.M_version();
    const std::string got = version ? version : "";
    if (!options.expectedVersion.empty() && got != options.expectedVersion) {
        error = "MAX: " + lib.string() + " is version " + (got.empty() ? "(unknown)" : got) +
                ", but eco was built for " + options.expectedVersion +
                " (deps/versions.env MAX_VERSION); reconfigure to re-sync the MAX environment";
        return nullptr;
    }
    return &api;
}

} // namespace

const Api *load(const LoadOptions &options, std::string &error) {
    static std::once_flag once;
    static const Api *api = nullptr;
    static std::string firstError;
    std::call_once(once, [&] { api = loadOnce(options, firstError); });
    if (!api)
        error = firstError;
    return api;
}

} // namespace eco::max
