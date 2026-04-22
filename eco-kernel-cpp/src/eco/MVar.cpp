//===- MVar.cpp - MVar kernel module implementation -----------------------===//
//
// Single-threaded MVar implementation. Blocking operations (reading an empty
// MVar, putting into a full one) assert-crash because proper blocking requires
// cooperative scheduler integration (future work).
//
//===----------------------------------------------------------------------===//

#include "MVar.hpp"
#include "ExportHelpers.hpp"
#include "KernelHelpers.hpp"
#include "allocator/Allocator.hpp"
#include "allocator/RootSet.hpp"
#include <cassert>
#include <optional>
#include <unordered_map>

namespace Eco::Kernel::MVar {

struct MVarSlot {
    std::optional<HPointer> value;
};

static std::unordered_map<int64_t, MVarSlot> s_mvars;
static int64_t s_nextId = 1;

int64_t newEmpty() {
    int64_t id = s_nextId++;
    s_mvars[id] = MVarSlot{};
    return id;
}

uint64_t read(uint64_t id) {
    int64_t mvarId = static_cast<int64_t>(id);
    auto it = s_mvars.find(mvarId);
    assert(it != s_mvars.end() && "MVar not found");
    assert(it->second.value.has_value() && "MVar.read: MVar is empty (blocking not implemented)");
    return taskSucceed(it->second.value.value());
}

uint64_t take(uint64_t id) {
    int64_t mvarId = static_cast<int64_t>(id);
    auto it = s_mvars.find(mvarId);
    assert(it != s_mvars.end() && "MVar not found");
    assert(it->second.value.has_value() && "MVar.take: MVar is empty (blocking not implemented)");
    HPointer val = it->second.value.value();
    it->second.value.reset();
    return taskSucceed(val);
}

uint64_t put(uint64_t id, uint64_t value) {
    int64_t mvarId = static_cast<int64_t>(id);
    auto it = s_mvars.find(mvarId);
    assert(it != s_mvars.end() && "MVar not found");
    assert(!it->second.value.has_value() && "MVar.put: MVar is full (blocking not implemented)");
    it->second.value = Export::decode(value);
    return taskSucceedUnit();
}

uint64_t drop(uint64_t id) {
    int64_t mvarId = static_cast<int64_t>(id);
    s_mvars.erase(mvarId);
    return taskSucceedUnit();
}

void registerGcRootScanner() {
    Elm::Allocator::instance().getRootSet().addExternalRootScanner(
        [](Elm::RootSet::EvacuateFn evacuate) {
            for (auto& [id, slot] : s_mvars) {
                if (!slot.value.has_value()) continue;
                uint64_t encoded = Export::encode(slot.value.value());
                evacuate(encoded);
                slot.value = Export::decode(encoded);
            }
        });
}

} // namespace Eco::Kernel::MVar
