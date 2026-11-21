#pragma once

#include "../TestSuite.hpp"

// Registers the tests that tagged heap words (F1, HEAP_086) survive every collection.
void registerTaggedWordGcTests(Testing::TestSuite& suite);
