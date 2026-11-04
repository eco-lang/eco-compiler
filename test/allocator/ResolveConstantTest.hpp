#pragma once

#include "../IsolatedTestRunner.hpp"

// The contract of Allocator::resolve for an embedded constant: it dies, never returns null.
// Forks from a spawned child.
void registerResolveConstantTests(IsolatedTestRunner::IsolatedTestCaseSuite& suite);
