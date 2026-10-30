#pragma once

#include "../TestSuite.hpp"

// Checks that the JIT's runtime symbol map (runtime/src/codegen/RuntimeSymbols.cpp) lists every runtime
// function the lowering can declare (EcoRuntime::materializeAllRuntimeDecls), so `ecoc -emit=jit` never
// depends on the host process exporting a runtime symbol (cpp-review-bugs.md, "eco_enable_list_chunks is
// missing from the JIT symbol map").
void registerRuntimeSymbolMapTests(Testing::TestSuite& suite);
