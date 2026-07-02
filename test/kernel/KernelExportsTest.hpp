#ifndef KERNEL_EXPORTS_TEST_HPP
#define KERNEL_EXPORTS_TEST_HPP

#include "../TestSuite.hpp"
#include "../IsolatedTestRunner.hpp"

// Kernel extern-"C" ABI tests (encoder serializer, decoders, closure-driven
// string ops) that are otherwise reachable only via E2E.
void registerKernelExportsTests(Testing::TestSuite& suite);

// Crash-risk: elm_bytebuffer_len / Bytes.width on a Tag_ByteBufferSlice aborts
// in assert builds (F3). Added to a fork-isolated suite so each abort reports
// as a single failed test.
void registerKernelExportsCrasherTests(IsolatedTestRunner::IsolatedTestCaseSuite& suite);

#endif  // KERNEL_EXPORTS_TEST_HPP
