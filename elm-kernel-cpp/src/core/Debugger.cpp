/**
 * Elm Kernel Debugger Module - Runtime Heap Integration
 *
 * Provides debugger operations using GC-managed heap values.
 * Note: This is a stub - full implementation requires platform-specific UI.
 */

#include "Debugger.hpp"
#include "allocator/Allocator.hpp"
#include "allocator/StringOps.hpp"
#include <cassert>

namespace Elm::Kernel::Debugger {

// ============================================================================
// Value display initialization - Stub
// ============================================================================

HPointer init(HPointer value) {
    // Stub - return a simple Expando representing the value
    (void)value;

    // Return Primitive("<value>")
    HPointer label = alloc::allocStringFromUTF8("<value>");
    return alloc::custom(0, {alloc::boxed(label)}, 0);
}

// ============================================================================
// Debugger window state - Stubs
// ============================================================================

bool isOpen(HPointer popout) {
    // Stub - always return false (no popout window)
    (void)popout;
    return false;
}

HPointer open(HPointer popout) {
    (void)popout;
    assert(false && "not implemented");
    return alloc::unit();
}

HPointer scroll(HPointer popout) {
    (void)popout;
    assert(false && "not implemented");
    return alloc::unit();
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

HPointer download(i64 historyLength, HPointer json) {
    (void)historyLength;
    (void)json;
    assert(false && "not implemented");
    return alloc::unit();
}

HPointer upload() {
    assert(false && "not implemented");
    return alloc::unit();
}

// ============================================================================
// Type coercion
// ============================================================================

HPointer unsafeCoerce(HPointer value) {
    // Identity function
    return value;
}

} // namespace Elm::Kernel::Debugger
