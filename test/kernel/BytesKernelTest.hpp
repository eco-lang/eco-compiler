#pragma once

#include "../IsolatedTestRunner.hpp"

// Bytes kernel exports (elm-kernel-cpp/src/bytes/BytesExports.cpp): the read_bytes length check and
// the 4 GiB width limit of an encoding. Each case initializes the allocator: spawned child.
void registerBytesKernelTests(IsolatedTestRunner::IsolatedTestCaseSuite& suite);
