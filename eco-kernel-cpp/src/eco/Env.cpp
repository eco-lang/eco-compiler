//===- Env.cpp - Env kernel module implementation -------------------------===//

#include "Env.hpp"
#include "KernelHelpers.hpp"
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

uint64_t lookup(uint64_t name) {
    std::string key = toString(name);
    const char* value = std::getenv(key.c_str());
    return taskSucceedMaybeString(value);
}

uint64_t rawArgs() {
    std::vector<std::string> args;
    for (int i = 0; i < s_argc; ++i) {
        args.push_back(s_argv[i]);
    }
    return taskSucceedStringList(args);
}

} // namespace Eco::Kernel::Env
