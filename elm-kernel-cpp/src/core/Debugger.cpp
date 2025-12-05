/**
 * Elm Kernel Debugger Module - Runtime Heap Integration
 *
 * Provides debugger operations using GC-managed heap values.
 * Note: This is a stub - full implementation requires platform-specific UI.
 */

#include "Debugger.hpp"
#include "allocator/Allocator.hpp"
#include "allocator/StringOps.hpp"

namespace Elm::Kernel::Debugger {

// Expando constructor tags
constexpr u16 TAG_PRIMITIVE = 0;
constexpr u16 TAG_STRING = 1;
constexpr u16 TAG_CONSTRUCTOR = 2;
constexpr u16 TAG_SEQUENCE = 3;
constexpr u16 TAG_DICTIONARY = 4;
constexpr u16 TAG_RECORD = 5;

// ============================================================================
// Value display initialization - Stub
// ============================================================================

HPointer init(HPointer value) {
    // Stub - return a simple Expando representing the value
    (void)value;

    // Return Primitive("<value>")
    HPointer label = alloc::allocStringFromUTF8("<value>");
    return alloc::custom(TAG_PRIMITIVE, {alloc::boxed(label)}, 0);
}

// ============================================================================
// Debugger window state - Stubs
// ============================================================================

bool isOpen(HPointer popout) {
    // Stub - always return false (no popout window)
    (void)popout;
    return false;
}

TaskPtr open(HPointer popout) {
    (void)popout;
    return Scheduler::binding([](Scheduler::Callback callback) -> std::function<void()> {
        callback(alloc::unit());
        return []() {};
    });
}

TaskPtr scroll(HPointer popout) {
    (void)popout;
    return Scheduler::binding([](Scheduler::Callback callback) -> std::function<void()> {
        callback(alloc::unit());
        return []() {};
    });
}

// ============================================================================
// Message display - Stub
// ============================================================================

HPointer messageToString(HPointer message) {
    // Stub - return "<message>"
    (void)message;
    return alloc::allocStringFromUTF8("<message>");
}

// ============================================================================
// History upload/download - Stubs
// ============================================================================

TaskPtr download(i64 historyLength, HPointer json) {
    (void)historyLength;
    (void)json;
    return Scheduler::binding([](Scheduler::Callback callback) -> std::function<void()> {
        callback(alloc::unit());
        return []() {};
    });
}

TaskPtr upload() {
    return Scheduler::binding([](Scheduler::Callback callback) -> std::function<void()> {
        // Return empty string (no file selected)
        callback(alloc::emptyString());
        return []() {};
    });
}

// ============================================================================
// Type coercion
// ============================================================================

HPointer unsafeCoerce(HPointer value) {
    // Identity function
    return value;
}

} // namespace Elm::Kernel::Debugger
