#pragma once

#include "TestSuite.hpp"

// Unit tests for getObjectSize() function in AllocatorCommon.hpp

// Fixed-size object tests
extern Testing::TestCase testGetObjectSizeInt;
extern Testing::TestCase testGetObjectSizeFloat;
extern Testing::TestCase testGetObjectSizeChar;
extern Testing::TestCase testGetObjectSizeTuple2;
extern Testing::TestCase testGetObjectSizeTuple3;
extern Testing::TestCase testGetObjectSizeCons;
extern Testing::TestCase testGetObjectSizeProcess;
extern Testing::TestCase testGetObjectSizeTask;
extern Testing::TestCase testGetObjectSizeForward;

// Variable-size object tests (using hdr->size)
extern Testing::TestCase testGetObjectSizeString;
extern Testing::TestCase testGetObjectSizeStringEdgeCases;
extern Testing::TestCase testGetObjectSizeCustom;
extern Testing::TestCase testGetObjectSizeCustomEdgeCases;
extern Testing::TestCase testGetObjectSizeRecord;
extern Testing::TestCase testGetObjectSizeRecordEdgeCases;
extern Testing::TestCase testGetObjectSizeDynRecord;
extern Testing::TestCase testGetObjectSizeDynRecordEdgeCases;
extern Testing::TestCase testGetObjectSizeFieldGroup;
extern Testing::TestCase testGetObjectSizeFieldGroupEdgeCases;

// Closure tests (uses n_values field)
extern Testing::TestCase testGetObjectSizeClosure;
extern Testing::TestCase testGetObjectSizeClosureEdgeCases;

// Alignment tests
extern Testing::TestCase testGetObjectSizeAlwaysAligned;

// Edge case tests
extern Testing::TestCase testGetObjectSizeUnknownTag;
extern Testing::TestCase testGetObjectSizeAllTagsExhaustive;
