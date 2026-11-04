#ifndef ECO_MVAR_HPP
#define ECO_MVAR_HPP

// MVar gives the compiler's Elm code a way for fibers on the one eco thread to hand values to each other and
// wait for each other, without blocking the thread.
//
// An MVar is a box with one slot that is either empty or full, named by an integer id. Ids count up from 1
// and are never reused, including after `drop`. Reading or taking from an empty MVar, or putting into a full
// one, does not block: the calling fiber is *parked* (its resume closure is handed to the scheduler, under a
// `HoldKind::Task` hold) and is resumed later by the complementary operation. Each MVar keeps three queues
// of parked fibers, one per wake condition:
//
// - *readers*, parked by `read` on empty. All of them are resumed with the next value that arrives.
// - *takers*, parked by `take` on empty. The first in line receives the next value and consumes it.
// - *putters*, parked by `put` on full, each with its value. When a take empties the slot, the first in line
//   puts its value, as `put` on an empty MVar does, and is resumed with unit.
//
// So a full MVar has no parked readers or takers, and an empty one has no parked putters.
//
// `read`, `take`, `put` and `drop` return a Binding Task and touch no MVar state when called. The operation
// happens each time the Task is run (its *fulfilment*), so one Task value run twice performs it twice. The
// Tasks and `put`'s value cross as encoded words (`Export::encode`); ids are plain integers. A Task for an
// id that names no MVar when it is run fails with the IO error tuple (tag 0, empty path,
// "MVar not found: <id>"); `drop` instead succeeds.
//
// All state is unguarded module-level data, so every function must be called on the eco thread. Every
// function but `newEmpty` and `registerGcRootScanner` allocates and is a GC point.

#include <cstdint>

namespace Eco::Kernel::MVar {

/// Creates an empty MVar and returns its id.
int64_t newEmpty();
/// Returns a Task that, when run, succeeds with the value in MVar `id` and leaves it full, or, if the MVar is
/// empty, parks as a reader until a value arrives and succeeds with that value.
uint64_t read(uint64_t id);
/// Returns a Task that, when run, empties MVar `id` and succeeds with the value it held, or, if the MVar is
/// empty, parks as a taker until it receives a value. Emptying the MVar lets the first parked putter, if
/// any, put its value before this Task's caller is resumed.
uint64_t take(uint64_t id);
/// Returns a Task that, when run, puts the encoded heap value `value` into MVar `id` and succeeds with unit,
/// or, if the MVar is full, parks as a putter until a take makes room. Putting into an empty MVar resumes
/// every parked reader with `value` and then hands it to the first parked taker; the MVar is left full only
/// when there was no taker.
uint64_t put(uint64_t id, uint64_t value);
/// Returns a Task that, when run, removes MVar `id` and succeeds with unit. Fibers parked on it are never
/// resumed: their resume closures are discarded and their holds released, and a parked putter's value is
/// dropped. An unknown `id` is not an error.
uint64_t drop(uint64_t id);

/// Registers a scanner with the allocator's root set that keeps every MVar's value and every parked putter's
/// value alive, and updates them when the collector moves them. Each call registers another scanner, and
/// nothing here registers one again after the root set's scanners are cleared.
void registerGcRootScanner();

} // namespace Eco::Kernel::MVar

#endif // ECO_MVAR_HPP
