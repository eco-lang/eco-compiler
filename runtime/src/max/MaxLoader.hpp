/// \file MaxLoader.hpp
/// Loads Modular MAX's engine library (libmax) into the process on first use.
///
/// eco does not link libmax: the library is about 300 MB with its kernel packages, comes from the
/// `max` Python wheel that deps/max/ pins (installed by uv), and exists only for Linux glibc and
/// macOS arm64. eco loads it with dlopen when something first asks for it, so a program that
/// never uses MAX neither needs nor loads it, and builds without MAX link exactly as before.
///
/// Every C API function eco calls is listed once, in ECO_MAX_FUNCTIONS; the loader resolves all of
/// them and refuses a library that lacks any, so a MAX upgrade that renames or drops one fails at
/// load time with the function's name, not at the first call.
///
/// Before handing a module to MAX, check it with eco::max::verifyModule (MaxVerify.hpp):
/// M_compileModelSync crashes on input it cannot parse instead of reporting an error.
#pragma once

#include "max/c/common.h"
#include "max/c/context.h"
#include "max/c/device.h"
#include "max/c/model.h"
#include "max/c/tensor.h"
#include "max/c/types.h"

#include <filesystem>
#include <string>

namespace eco::max {

/// The C API functions eco uses. Add one here (and only here) to use it.
#define ECO_MAX_FUNCTIONS(X)                                                                      \
    X(M_version)                                                                                  \
    X(M_newStatus)                                                                                \
    X(M_freeStatus)                                                                               \
    X(M_isError)                                                                                  \
    X(M_getError)                                                                                 \
    X(M_newRuntimeConfig)                                                                         \
    X(M_freeRuntimeConfig)                                                                        \
    X(M_newDevice)                                                                                \
    X(M_freeDevice)                                                                               \
    X(M_runtimeConfigAddDevice)                                                                   \
    X(M_newRuntimeContext)                                                                        \
    X(M_freeRuntimeContext)                                                                       \
    X(M_newCompileConfig)                                                                         \
    X(M_freeCompileConfig)                                                                        \
    X(M_setModelPath)                                                                             \
    X(M_compileModelSync)                                                                         \
    X(M_freeCompiledModel)                                                                        \
    X(M_initModel)                                                                                \
    X(M_waitForModel)                                                                             \
    X(M_freeModel)                                                                                \
    X(M_newTensorSpec)                                                                            \
    X(M_freeTensorSpec)                                                                           \
    X(M_newAsyncTensorMap)                                                                        \
    X(M_freeAsyncTensorMap)                                                                       \
    X(M_borrowTensorInto)                                                                         \
    X(M_executeModelSync)                                                                         \
    X(M_getTensorByNameFrom)                                                                      \
    X(M_getTensorData)                                                                            \
    X(M_freeTensor)

/// One function pointer per entry of ECO_MAX_FUNCTIONS, typed from MAX's own declarations.
struct Api {
#define ECO_MAX_API_MEMBER(name) decltype(&::name) name = nullptr;
    ECO_MAX_FUNCTIONS(ECO_MAX_API_MEMBER)
#undef ECO_MAX_API_MEMBER
};

/// Where MAX is and which version eco expects.
struct LoadOptions {
    /// The `modular` directory of the installed wheel (site-packages/modular): it holds
    /// lib/libmax.so (lib/libmax.dylib on macOS) and lib/mojo, the kernel packages.
    std::filesystem::path packageRoot;
    /// The MAX version eco was built against (deps/versions.env MAX_VERSION). A library reporting
    /// another version is refused. Empty skips the check.
    std::string expectedVersion;
};

/// Loads libmax once per process and returns its functions, or nullptr with `error` set. Later
/// calls return the first result (and the first error), whatever their options. Thread-safe.
///
/// Before loading, it sets the variables libmax reads at start-up, keeping any the user has set:
///   - MODULAR_MAX_PACKAGE_ROOT, MODULAR_MOJO_MAX_PACKAGE_ROOT: packageRoot;
///   - MODULAR_MOJO_MAX_IMPORT_PATH: packageRoot/lib/mojo;
///   - MODULAR_TELEMETRY_ENABLED=0: MAX sends telemetry by default; eco opts out unless asked;
///   - MODULAR_THREAD_BUSY_WAIT_US and MODULAR_RUNTIME_THREAD_BUSY_WAIT_TIME_US: MAX aborts when
///     they differ, so when only one is set the other is given the same value.
const Api *load(const LoadOptions &options, std::string &error);

} // namespace eco::max
