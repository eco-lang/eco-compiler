//===- CellStore.hpp - Off-heap mutable cell vectors ----------------------===//
//
// A CellStore is an index-addressed, MUTABLE vector of boxed Elm values that
// lives OFF the Elm heap, with an undo trail so a caller can speculate and
// roll back.
//
// Why off the heap: the generational collector has no write barrier, no
// remembered set and no card table, and HEAP_005 ("there are no old to young
// pointers in the heap") is the invariant that licenses that. A long-lived
// HEAP object mutated to point at a nursery object would therefore be
// invisible to a minor GC — a dangling cell, not a slow path. The sanctioned
// way to hold mutable state that references Elm values is to keep it outside
// the heap and register it with RootSet::addExternalRootScanner, which is what
// the list scratch stack (HEAP_040) and Eco::Kernel::MVar already do.
//
// The cells and the trail are both scanned: a rolled-back value must stay
// alive and correctly forwarded until the rollback puts it back.
//
// Handles are int64_t indices into a table of stores. Ids are NEVER reused, so
// a use-after-dispose aborts loudly instead of silently reading another
// store's cells.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_CELLSTORE_HPP
#define ECO_CELLSTORE_HPP

#include <cstdint>

namespace Eco::Kernel::CellStore {

// Create a store. `cap` is a capacity hint (<= 0 means "use the default").
int64_t newStore(int64_t cap);

// Number of cells.
int64_t size(int64_t h);

// Read cell `ix`. Aborts if out of range.
uint64_t get(int64_t ix, int64_t h);

// Write cell `ix`; returns the handle. Aborts if out of range.
int64_t set(int64_t ix, uint64_t word, int64_t h);

// Append a cell at index `size(h)`; returns the handle.
int64_t push(uint64_t word, int64_t h);

// Open an undo scope. Nestable.
int64_t pushMark(int64_t h);

// Close the innermost scope, restoring every cell AND the cell count.
int64_t rollback(int64_t h);

// Close the innermost scope, keeping the writes.
int64_t commit(int64_t h);

// Free the store. Idempotent. Returns `x` unchanged so the call can be a data
// dependency rather than a discarded statement.
uint64_t disposeThen(int64_t h, uint64_t x);

void registerGcRootScanner();

} // namespace Eco::Kernel::CellStore

#endif // ECO_CELLSTORE_HPP
