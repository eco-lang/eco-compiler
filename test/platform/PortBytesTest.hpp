#ifndef PORT_BYTES_TEST_HPP
#define PORT_BYTES_TEST_HPP

#include "../IsolatedTestRunner.hpp"

// Unit tests for plans/native-bytes-ports-2.md: the no-collection guard around host callbacks (HEAP_083), Bytes
// allocated without collecting, owned (retained) bytes, port handles (PORT_011) and subscriber lifetimes
// (PORT_010). The paths that need a running program, the direct and off-heap emits into a registered port, are
// covered end to end by test/eco-divergence/src/PortBytesEmitTest.elm.
//
// Child-process isolated: the guard's cases end their process, and PortRuntime is a process singleton.
void registerPortBytesTests(IsolatedTestRunner::IsolatedTestCaseSuite& suite);

#endif  // PORT_BYTES_TEST_HPP
