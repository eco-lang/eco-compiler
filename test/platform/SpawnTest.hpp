#pragma once

#include "../IsolatedTestRunner.hpp"

// plans/spawn-not-fork.md: the spawn primitive (runtime/src/platform/Spawn.hpp).
void registerSpawnTests(IsolatedTestRunner::IsolatedTestCaseSuite& suite);
