#include "List.hpp"
#include "allocator/Allocator.hpp"

namespace Elm::Kernel::List {

// ============================================================================
// Construction
// ============================================================================

HPointer cons(Unboxable head, HPointer tail, bool headIsBoxed) {
    return alloc::cons(head, tail, headIsBoxed);
}

} // namespace Elm::Kernel::List
