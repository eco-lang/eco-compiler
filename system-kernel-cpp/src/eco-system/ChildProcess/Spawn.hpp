//===- Spawn.hpp - the runtime's spawn primitive, under its eco-system names ===//
//
// plans/spawn-not-fork.md Phase 1: the implementation moved to the runtime
// (runtime/src/platform/Spawn.{hpp,cpp}), which Eco.Process and the test
// harnesses share. The eco-system ChildProcess module keeps these names.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_SYSTEM_CHILD_PROCESS_SPAWN_HPP
#define ECO_SYSTEM_CHILD_PROCESS_SPAWN_HPP

#include "platform/Spawn.hpp"

namespace Eco::System {

using Elm::platform::kShellNone;
using Elm::platform::kShellDefault;
using Elm::platform::kShellCustom;
using Elm::platform::kEnvInherit;
using Elm::platform::kEnvMerge;
using Elm::platform::kEnvReplace;
using Elm::platform::SpawnSpec;
using Elm::platform::StdioMode;
using Elm::platform::SpawnedChild;
using Elm::platform::spawnChild;

} // namespace Eco::System

#endif // ECO_SYSTEM_CHILD_PROCESS_SPAWN_HPP
