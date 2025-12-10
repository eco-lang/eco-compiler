#ifndef ECO_DEBUGGER_HPP
#define ECO_DEBUGGER_HPP

/**
 * Elm Kernel Debugger Module - Runtime Heap Integration
 *
 * Provides debugger operations using GC-managed heap values.
 * Note: This is a stub - full implementation requires platform-specific UI.
 */

#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "Scheduler.hpp"

namespace Elm::Kernel::Debugger {

using TaskPtr = Scheduler::TaskPtr;

// Expando types for debugger value display.
enum class ExpandoTag {
    Primitive,    // Primitive value (number, bool, etc.).
    S,            // String value.
    Constructor,  // Custom type constructor.
    Sequence,     // List, Array, Set.
    Dictionary,   // Dict.
    Record        // Record.
};

enum class SequenceTag {
    ListSeq,
    ArraySeq,
    SetSeq
};

// Initializes a value for debugger display (converts to Expando).
HPointer init(HPointer value);

// Checks if debugger window is open.
bool isOpen(HPointer popout);

// Opens the debugger popout window.
TaskPtr open(HPointer popout);

// Scrolls debugger sidebar to bottom.
TaskPtr scroll(HPointer popout);

// Converts a message value to display string.
HPointer messageToString(HPointer message);

// Downloads history as JSON file.
TaskPtr download(i64 historyLength, HPointer json);

// Uploads history file.
TaskPtr upload();

// Identity function (for internal type coercion).
HPointer unsafeCoerce(HPointer value);

} // namespace Elm::Kernel::Debugger

#endif // ECO_DEBUGGER_HPP
