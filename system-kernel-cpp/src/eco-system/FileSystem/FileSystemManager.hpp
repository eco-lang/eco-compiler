//===- FileSystemManager.hpp - The C++ effect manager of `FileSystem` ----===//
//
// The Elm module `FileSystem` (system-kernel-cpp/src/FileSystem.elm) is an
// effect module whose one subscription, `Watch path recursive tagger`, asks
// to be told about changes under a path. In native builds that subscription
// is served by this C++ effect manager, registered under the name
// "FileSystem"; the Elm manager functions in the module are not run.
//
// Because the manager reads Elm values directly from the heap, it depends on
// the layout the compiler gives `MySub`:
//
//     type MySub msg = Watch String Bool (( Int, Maybe String ) -> msg)
//
// `Watch` is constructor tag 0 (tags are zero-based declaration indexes),
// and its three fields are boxed values in declaration order. The constants
// below mirror that declaration, and nothing checks that the two agree, so a
// change to one must be made to the other.
//
// A tagger receives an event as the tuple `( kind, relativePath )`. `kind` is
// `KIND_CHANGED` or `KIND_MOVED`, and is stored unboxed. `relativePath` is
// `Just` a path relative to the watched one, with `/` separators, or
// `Nothing` when the event is about the watched path itself.
//
// Subscriptions with the same path and the same `recursive` flag share one
// `Fs::WatchService` watch, and each event of that watch is delivered to all
// of their taggers. While a watch is active it keeps the program from
// exiting. A path that cannot be watched produces no events, keeps nothing
// alive, and reports no error. On Windows any `Watch` subscription ends the
// process with a fatal error.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_FILESYSTEM_FILESYSTEM_MANAGER_HPP
#define ECO_SYSTEM_FILESYSTEM_FILESYSTEM_MANAGER_HPP

#include <cstdint>

namespace Eco::System::FileSystemManager {

/// The constructor tag of `Watch`, the only constructor of `MySub`.
constexpr uint16_t CTOR_WATCH = 0;
/// The field of a `Watch` holding the watched path, an Elm `String`.
constexpr int WATCH_PATH_FIELD = 0;
/// The field of a `Watch` holding `recursive`, a boxed `Bool` constant.
constexpr int WATCH_RECURSIVE_FIELD = 1;
/// The field of a `Watch` holding the tagger, of type
/// `( Int, Maybe String ) -> msg`.
constexpr int WATCH_TAGGER_FIELD = 2;

/// The event kind meaning that an entry's contents or attributes changed.
/// The Elm module turns it into `Changed`.
constexpr int KIND_CHANGED = 0;
/// The event kind meaning that an entry was created, deleted, renamed or replaced.
/// The Elm module turns it into `Moved`.
constexpr int KIND_MOVED = 1;

} // namespace Eco::System::FileSystemManager

extern "C" {
/// Registers the `FileSystem` effect manager with the platform runtime, under
/// the name "FileSystem". Returns the encoded unit value. A native exception
/// ends the process with a fatal error.
uint64_t Eco_System_registerManager_FileSystem();
}

#endif // ECO_SYSTEM_FILESYSTEM_FILESYSTEM_MANAGER_HPP
