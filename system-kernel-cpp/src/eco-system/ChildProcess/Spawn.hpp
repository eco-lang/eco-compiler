//===- Spawn.hpp - the runtime's spawn primitive, under its eco-system names ===//
//
// The eco-system ChildProcess code starts child processes with the runtime's spawn primitive, which lives in
// `Elm::platform` (runtime/src/platform/Spawn.hpp). This header brings that primitive into `Eco::System` with
// `using` declarations, so the ChildProcess files name it without the namespace. It defines nothing of its own:
// `spawnChild`, `SpawnSpec`, `StdioMode`, `SpawnedChild` and the `kShell*` and `kEnv*` constants are the
// runtime's, and their contracts are stated on the declarations in platform/Spawn.hpp.
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
