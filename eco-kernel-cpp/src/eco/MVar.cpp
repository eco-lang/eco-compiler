//===- MVar.cpp - MVar kernel module implementation -----------------------===//
//
// Single-threaded MVar implementation. Blocking operations (reading an empty
// MVar, putting into a full one) assert-crash because proper blocking requires
// cooperative scheduler integration (future work).
//
//===----------------------------------------------------------------------===//

#include "MVar.hpp"
#include "KernelHelpers.hpp"
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

uint64_t read(uint64_t /*typeTag*/, uint64_t id) {
    int64_t mvarId = static_cast<int64_t>(id);
    auto it = s_mvars.find(mvarId);
    assert(it != s_mvars.end() && "MVar not found");
    assert(it->second.value.has_value() && "MVar.read: MVar is empty (blocking not implemented)");
    return taskSucceed(it->second.value.value());
}

uint64_t take(uint64_t /*typeTag*/, uint64_t id) {
    int64_t mvarId = static_cast<int64_t>(id);
    auto it = s_mvars.find(mvarId);
    assert(it != s_mvars.end() && "MVar not found");
    assert(it->second.value.has_value() && "MVar.take: MVar is empty (blocking not implemented)");
    HPointer val = it->second.value.value();
    it->second.value.reset();
    return taskSucceed(val);
}

uint64_t put(uint64_t /*typeTag*/, uint64_t id, uint64_t value) {
    int64_t mvarId = static_cast<int64_t>(id);
    auto it = s_mvars.find(mvarId);
    assert(it != s_mvars.end() && "MVar not found");
    assert(!it->second.value.has_value() && "MVar.put: MVar is full (blocking not implemented)");
    it->second.value = Export::decode(value);
    return taskSucceedUnit();
}

} // namespace Eco::Kernel::MVar
