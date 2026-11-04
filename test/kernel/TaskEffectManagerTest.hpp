#pragma once

#include "../IsolatedTestRunner.hpp"

// The Task effect manager's registrar (eco_register_task_effect_manager) across a minor GC.
// Each case initializes its own allocator: spawned child.
void registerTaskEffectManagerTests(IsolatedTestRunner::IsolatedTestCaseSuite& suite);
