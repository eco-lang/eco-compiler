#pragma once

#include "TestSuite.hpp"

// Compaction tests.
extern Testing::UnitTest testBlockInitialization;
extern Testing::TestCase testBlockLiveInfoTracking;
extern Testing::UnitTest testCompactionSetSelection;
extern Testing::TestCase testObjectEvacuationWithForwarding;
extern Testing::TestCase testReadBarrierSelfHealing;
extern Testing::TestCase testBlockEvacuation;
extern Testing::UnitTest testBlockReclaimToTLABs;
extern Testing::TestCase testCompactionPreservesValues;
extern Testing::TestCase testRootPointerUpdatesAfterCompaction;
extern Testing::TestCase testFragmentationDefragmentation;
