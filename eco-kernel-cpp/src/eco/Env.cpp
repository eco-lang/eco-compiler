//===- Env.cpp - Env kernel module implementation -------------------------===//
//
// Per KERNEL_TASK_IO_001 / plans/defer-eager-kernel-tasks-via-binding.md
// Phase 2: `lookup`, `rawArgs` are returned as Task_Bindings so the env-var
// read (`getenv`) and the argv walk happen when the scheduler steps the
// binding, not at the kernel call site.
//
//===----------------------------------------------------------------------===//

#include "Env.hpp"
#include "KernelHelpers.hpp"
#include "TaskBinding.hpp"
#include <cstdlib>
#include <string>
#include <vector>

namespace Eco::Kernel::Env {

static int s_argc = 0;
static char** s_argv = nullptr;

void init(int argc, char** argv) {
    s_argc = argc;
    s_argv = argv;
}

namespace {

// Body for `lookup`. Captured payload is the name String HPointer directly.
HPointer lookupBody(HPointer captured) {
    std::string key = toString(Export::encode(captured));
    const char* value = std::getenv(key.c_str());
    return succeedMaybeString(value);
}

// Body for `rawArgs`. Captured payload is unit() (no args). Reads `s_argv`
// at evaluator-step time so successive calls observe any post-init mutation
// of the static storage (defensive — Env::init is currently called once at
// startup, but the binding contract doesn't depend on that).
HPointer rawArgsBody(HPointer /*captured*/) {
    std::vector<std::string> args;
    // Skip argv[0] (program name) to match the JS convention
    // where process.argv.slice(2) strips both 'node' and the script path.
    for (int i = 1; i < s_argc; ++i) {
        args.push_back(s_argv[i]);
    }
    return succeedStringList(args);
}

} // anonymous namespace

uint64_t lookup(uint64_t name) {
    HPointer nameHP = Export::decode(name);
    return Export::encode(Eco::Kernel::makeBinding<lookupBody>(nameHP));
}

uint64_t rawArgs() {
    return Export::encode(
        Eco::Kernel::makeBinding<rawArgsBody>(Elm::alloc::unit()));
}

} // namespace Eco::Kernel::Env
