#pragma once

#include "TestSuite.hpp"

// Compaction tests.
extern Testing::TestCase testBlockInitialization;
extern Testing::TestCase testBlockLiveInfoTracking;
extern Testing::TestCase testCompactionSetSelection;
extern Testing::TestCase testObjectEvacuationWithForwarding;
extern Testing::TestCase testReadBarrierSelfHealing;
extern Testing::TestCase testBlockEvacuation;
extern Testing::TestCase testBlockReclaimToTLABs;
extern Testing::TestCase testCompactionPreservesValues;
extern Testing::TestCase testRootPointerUpdatesAfterCompaction;
extern Testing::TestCase testFragmentationDefragmentation;
