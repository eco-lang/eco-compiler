//===- Env.cpp - Env kernel module implementation -------------------------===//

#include "Env.hpp"
#include "KernelHelpers.hpp"
#include "TaskBinding.hpp"
#include <cstdlib>
#include <string>
#include <vector>

namespace Eco::Kernel::Env {

// The argv recorded by init; null, with s_argc 0, until init is called.
static int s_argc = 0;
static char** s_argv = nullptr;

void init(int argc, char** argv) {
    s_argc = argc;
    s_argv = argv;
}

namespace {

// The binding body of a `lookup` Task. `captured` is the name String itself. Nothing allocates on the Elm
// heap before `captured` is read, so it needs no rooting.
HPointer lookupBody(HPointer captured) {
    std::string key = toString(Export::encode(captured));
    const char* value = std::getenv(key.c_str());
    return succeedMaybeString(value);
}

// The binding body of a `rawArgs` Task. `captured` is Unit and unused. `s_argc` and `s_argv` are read when
// the Task is stepped, not when it is made.
HPointer rawArgsBody(HPointer /*captured*/) {
    std::vector<std::string> args;
    // Skip argv[0], the program name, matching the JS kernel, where process.argv.slice(2) drops both 'node'
    // and the script path.
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
