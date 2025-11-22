#pragma once

#include "TestSuite.hpp"

// NurserySpace (minor GC) property-based tests
extern Testing::Test testMinorGCPreservesRoots;
extern Testing::Test testMultipleMinorGCCycles;
extern Testing::Test testContinuousGarbageAllocation;
