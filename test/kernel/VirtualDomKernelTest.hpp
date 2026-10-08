#ifndef VIRTUAL_DOM_KERNEL_TEST_HPP
#define VIRTUAL_DOM_KERNEL_TEST_HPP

#include "../TestSuite.hpp"

// Native elm/html kernel tests (plans/elm-html-native-kernel.md P0.3, P0.4, P2,
// P4): the JsonRead mirror of the Json heap forms, the elm/virtual-dom 1.0.5
// XSS filters, the VirtualDom constructors' heap layout and GC rooting, eager
// lazy, and the C++ HTML writer.
void registerVirtualDomKernelTests(Testing::TestSuite& suite);

#endif  // VIRTUAL_DOM_KERNEL_TEST_HPP
