//===- RuntimeSymbols.h - JIT Symbol Registration for Eco Runtime ---------===//
//
// Code compiled by a JIT in this process calls the runtime and the Elm kernels by name, and this component
// tells the JIT where those functions are.
//
// Lowered Eco code calls C functions it does not define: the runtime's entry points (`eco_*`, declared in
// `RuntimeExports.h` and `PermanentSpace.hpp`), the fused Bytes encoder and decoder helpers (`elm_*`, in
// `ElmBytesRuntime.h`), and the kernel and effect-manager functions declared in `KernelExports.h`. An
// executable built ahead of time gets their addresses from the static link. Under a JIT this component
// binds them: each name is defined in the engine as an absolute symbol at the address of the function
// linked into this process.
//
// The list of names is written out by hand; a unit test (test/codegen/RuntimeSymbolMapTest.cpp) checks that
// every runtime declaration the lowering can emit is in it. `EcoJIT` also searches the process's exported symbols, so a
// name missing from the list still resolves if the host executable exports it, and fails only otherwise.
// The `__eco_alloc_inline` marker is left out on purpose: a call to it that survives the backend is a
// fatal backend error, and leaving it unmapped means one could never run even if it got past that.
// Of the two Char build-guard functions, `eco_char_case_expansion_on` and `eco_char_case_expansion_off`,
// only the one this runtime defines is listed, so code lowered for the other `ECO_CHAR_CASE_EXPANSION`
// setting fails to resolve.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_RUNTIME_SYMBOLS_H
#define ECO_RUNTIME_SYMBOLS_H

#include "llvm/Support/Error.h"

#include <string>
#include <vector>

namespace eco {
class EcoJIT;

//===----------------------------------------------------------------------===//
// Symbol Registration
//===----------------------------------------------------------------------===//

// Defines in `engine` every name this component lists, each at the address of its function in this
// process.
//
// Call it once per engine, before the code that calls these functions is compiled: `EcoJIT` compiles code
// when a symbol in it is first looked up, so the call must come before that lookup. Returns an error if a
// name is already defined (a second call, or a module that defines a runtime symbol's name).
llvm::Error registerRuntimeSymbols(eco::EcoJIT &engine);

// Returns every name `registerRuntimeSymbols` defines, unmangled. Used by the test that checks every
// runtime declaration the lowering can emit is listed (test/codegen/RuntimeSymbolMapTest.cpp).
std::vector<std::string> runtimeSymbolNames();

} // namespace eco

#endif // ECO_RUNTIME_SYMBOLS_H
