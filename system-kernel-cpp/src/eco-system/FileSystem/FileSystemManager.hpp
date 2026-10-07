//===- FileSystemManager.hpp - The C++ effect manager of `System.File` ----===//
//
// plans/eco-system-library.md §3.6 and Appendix C.2 (manager key
// "System.File"). The Elm declaration lives in
// system-kernel-cpp/src/System/File.elm, in the "EFFECT MANAGER" section:
//
//     type MySub msg = Watch String Bool (( Int, Maybe String ) -> msg)
//                      -- tag 0: [path boxed, recursive boxed, tagger boxed]
//
// The tagger argument is ( kind, relativePath ): kind 0 Changed, 1 Moved;
// the tuple's Int slot is unboxed (mask 0x1). Tags are the zero-based
// declaration indexes (Compiler/Data/CtorTag.elm). Keep the two in sync.
//
// Templates used: T6 (manager), T5 (state registry), T8/G12 (delivery).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_FILESYSTEM_FILESYSTEM_MANAGER_HPP
#define ECO_SYSTEM_FILESYSTEM_FILESYSTEM_MANAGER_HPP

#include <cstdint>

namespace Eco::System::FileSystemManager {

// MySub
constexpr uint16_t CTOR_WATCH = 0;
constexpr int WATCH_PATH_FIELD = 0;        // String
constexpr int WATCH_RECURSIVE_FIELD = 1;   // Bool (embedded constant)
constexpr int WATCH_TAGGER_FIELD = 2;      // ( Int, Maybe String ) -> msg

// Tagger argument kinds.
constexpr int KIND_CHANGED = 0;
constexpr int KIND_MOVED = 1;

} // namespace Eco::System::FileSystemManager

extern "C" {
// Called from the compiler-emitted @__eco_register_ports preamble (§3.6);
// returns `()` as the `!eco.value` result (T6).
uint64_t Eco_System_registerManager_System_File();
}

#endif // ECO_SYSTEM_FILESYSTEM_FILESYSTEM_MANAGER_HPP
