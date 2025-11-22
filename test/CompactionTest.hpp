#pragma once

#include "TestSuite.hpp"

// Compaction tests.
extern Testing::Test testBlockInitialization;
extern Testing::Test testBlockLiveInfoTracking;
extern Testing::Test testCompactionSetSelection;
extern Testing::Test testObjectEvacuationWithForwarding;
extern Testing::Test testReadBarrierSelfHealing;
extern Testing::Test testBlockEvacuation;
extern Testing::Test testBlockReclaimToTLABs;
extern Testing::Test testCompactionPreservesValues;
extern Testing::Test testRootPointerUpdatesAfterCompaction;
extern Testing::Test testFragmentationDefragmentation;
