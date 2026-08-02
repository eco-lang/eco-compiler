#ifndef CHUNKED_LIST_TEST_HPP
#define CHUNKED_LIST_TEST_HPP

#include "../TestSuite.hpp"

// Chunked-list representation tests (plans/chunked-list-representation.md §6
// L1.2): Tag_ConsChunk / Tag_ListBacking allocation, ListCursor iteration
// over pure-chunk and mixed (cell + chunk) spines, and GC survival across
// minor cycles and promotion.
void registerChunkedListTests(Testing::TestSuite& suite);

#endif // CHUNKED_LIST_TEST_HPP
