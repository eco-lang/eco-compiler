#pragma once

#include "test.hpp"

// Allocator/GC property-based tests
extern Testing::Test testGCPreservesRoots;
extern Testing::Test testMultipleGCCycles;
extern Testing::Test testContinuousGarbageAllocation;
