//===- Runtime.cpp - Runtime kernel module implementation -----------------===//

#include "Runtime.hpp"
#include "ExportHelpers.hpp"
#include "KernelHelpers.hpp"
#include "allocator/Allocator.hpp"
#include "allocator/RootSet.hpp"
#include <random>
#include <string>
#include <unistd.h>
#include <climits>

namespace Eco::Kernel::Runtime {

static HPointer s_savedState = {};
static bool s_hasState = false;

uint64_t dirname() {
    char buf[PATH_MAX];
    ssize_t len = readlink("/proc/self/exe", buf, sizeof(buf) - 1);
    if (len < 0) {
        return taskFailString("Cannot determine executable path");
    }
    buf[len] = '\0';
    // Extract directory component.
    std::string path(buf);
    auto pos = path.rfind('/');
    if (pos != std::string::npos) {
        path = path.substr(0, pos);
    }
    return taskSucceedString(path);
}

uint64_t random() {
    static std::mt19937_64 gen(std::random_device{}());
    static std::uniform_real_distribution<double> dist(0.0, 1.0);
    return taskSucceedFloat(dist(gen));
}

uint64_t saveState(uint64_t state) {
    s_savedState = Export::decode(state);
    s_hasState = true;
    return taskSucceedUnit();
}

uint64_t loadState() {
    if (s_hasState) {
        return taskSucceed(s_savedState);
    }
    return taskSucceed(Elm::alloc::nothing());
}

void registerGcRootScanner() {
    Elm::Allocator::instance().getRootSet().addExternalRootScanner(
        [](Elm::RootSet::EvacuateFn evacuate) {
            if (!s_hasState) return;
            uint64_t encoded = Export::encode(s_savedState);
            evacuate(encoded);
            s_savedState = Export::decode(encoded);
        });
}

} // namespace Eco::Kernel::Runtime
