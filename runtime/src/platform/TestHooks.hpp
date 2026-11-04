//===- TestHooks.hpp - Whether test-only fault hooks are compiled ---------===//
//
// A few runtime and kernel services carry test-only hooks: a fault a unit test arms to make the next
// call fail, or an accessor exposing state no Elm program can observe. Each hook is declared and
// defined only when `ECO_TEST_HOOKS` is 1, so a build without them has neither the code nor the
// branch.
//
// `ECO_TEST_HOOKS` is 1 in builds without `NDEBUG` or with a non-zero `ECO_HEAP_VALIDATE`, which are
// the `dev` and `build` presets and the test binaries, and 0 in the `release` presets, which define
// `NDEBUG`. (`ECO_HEAP_VALIDATE` is tested by value: allocator/AllocatorCommon.hpp defines it as 0
// when it is off.) A translation unit may define it on the command line
// to override that. A test that calls a hook guards the call with `#if ECO_TEST_HOOKS`.
//
// No hook changes behaviour until a test arms it: an unarmed hook is a load and a branch on the
// path it sits on.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_PLATFORM_TEST_HOOKS_HPP
#define ECO_PLATFORM_TEST_HOOKS_HPP

#if !defined(ECO_TEST_HOOKS)
#if !defined(NDEBUG) || (defined(ECO_HEAP_VALIDATE) && ECO_HEAP_VALIDATE)
#define ECO_TEST_HOOKS 1
#else
#define ECO_TEST_HOOKS 0
#endif
#endif

#endif // ECO_PLATFORM_TEST_HOOKS_HPP
