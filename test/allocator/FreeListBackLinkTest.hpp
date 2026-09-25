#pragma once

#include "../TestSuite.hpp"

// threaded-gc-01 Step 2: address-encoded free-list back-links (HEAP_052).
extern Testing::TestCase testFreeListBackLinkEncodeRoundTrip;
extern Testing::TestCase testFreeListBackLinksConsistentAfterChurn;
