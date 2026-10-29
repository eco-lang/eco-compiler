//===- EcoJIT.h - JIT execution engine with stack map support -------------===//
//
// Custom JIT execution engine for Eco, derived from MLIR's ExecutionEngine.
// Adds JITEventListener support to extract __LLVM_StackMaps from JIT'd code.
//
// Original: mlir/lib/ExecutionEngine/ExecutionEngine.cpp
// License:  Apache License v2.0 with LLVM Exceptions (SPDX: Apache-2.0)
//
//===----------------------------------------------------------------------===//

// The collector finds the roots held by a running function by unwinding the
// machine stack and looking each return address up in a stack map, a table
// LLVM emits for each safepoint call site that records where the live GC
// pointers are kept. Code compiled in-process has no executable file to read
// those tables and its unwind information from, so this component compiles an
// LLVM-dialect MLIR module in memory and supplies both from the loaded code.
//
// `EcoJIT` translates the module to LLVM IR, runs an optional transformer on
// it, and hands it to an ORC `LLJIT` that compiles for the host and links with
// RuntimeDyld. Two things are added to that engine:
//
// - Stack map capture. When an object is loaded, the bytes of its stack map
//   section are copied out of loaded memory, normally after relocation, so
//   that the function addresses in them are the final addresses. A section
//   with no load address gives its unrelocated file bytes instead.
//   `getStackMapData` returns the copy, in the form `StackMap::parse` reads.
// - Unwind registration. On POSIX hosts the object's `.eh_frame` section is
//   registered with the unwinder one FDE (frame description entry, the record
//   describing one function) at a time, skipping CIEs (the common records the
//   FDEs share). On Apple hosts every function is given a DWARF FDE, and a
//   shift RuntimeDyld applies to each FDE's start address is undone before
//   registration. On Windows no `.eh_frame` registration is done.
//
// Each function `f` the module defines without local linkage also gets a
// wrapper, `_mlir_f`, that takes all its arguments through one `void **`
// array. That is the calling convention of `lookupPacked` and `invokePacked`.

#ifndef ECO_JIT_H
#define ECO_JIT_H

#include "llvm/ExecutionEngine/ObjectCache.h"
#include "llvm/ExecutionEngine/Orc/LLJIT.h"
#include "llvm/ExecutionEngine/SectionMemoryManager.h"
#include "llvm/IR/LLVMContext.h"
#include "llvm/Support/Error.h"

#include <functional>
#include <memory>
#include <optional>
#include <vector>

namespace mlir {
class Operation;
}

namespace eco {

//===----------------------------------------------------------------------===//
// Stack Map Data
//===----------------------------------------------------------------------===//

/**
 * The raw bytes of the stack map section of a loaded JIT object, normally
 * as they stand in memory after relocation. A section with no load address
 * gives its unrelocated file bytes.
 *
 * Empty until an object with a stack map section has been loaded. Each such
 * load replaces the bytes, so only the most recently loaded object's section
 * is held.
 */
struct StackMapData {
    std::vector<uint8_t> bytes;

    // Returns a pointer to the first byte, valid until `bytes` is next
    // assigned or destroyed.
    const uint8_t *data() const { return bytes.data(); }
    // Returns the number of bytes held.
    size_t size() const { return bytes.size(); }
    // Returns whether no bytes are held.
    bool empty() const { return bytes.empty(); }
};

//===----------------------------------------------------------------------===//
// EcoJIT Options
//===----------------------------------------------------------------------===//

/**
 * The settings `EcoJIT::create` builds an engine with.
 */
struct EcoJITOptions {
    // A rewrite of the LLVM module, applied once inside `EcoJIT::create`
    // after translation from MLIR, after the packed wrappers are added and
    // before compilation. Empty means the module is compiled as translated.
    //
    // It is a `std::function`, which owns its callable; the callable must
    // own its state. A returned error is not reported: it is treated as
    // impossible, which aborts when assertions are on and is undefined
    // behaviour otherwise.
    std::function<llvm::Error(llvm::Module *)> transformer = {};

    // A code generation optimisation level to set on the target machine
    // builder. The compiler `create` installs uses a target machine made
    // before this is applied, so setting it may change nothing.
    std::optional<llvm::CodeGenOptLevel> jitCodeGenOptLevel;
};

//===----------------------------------------------------------------------===//
// EcoJIT
//===----------------------------------------------------------------------===//

/**
 * An in-memory compilation of one MLIR module, together with the stack maps
 * and unwind information the collector needs to walk its frames.
 *
 * The only way to make one is `create`. The engine owns all the code it
 * compiles, which stays callable until the engine is destroyed. Destruction
 * runs the module's deinitializers, ignoring any error, and then destroys
 * the underlying engine and the code with it. An `EcoJIT` can
 * be neither copied nor moved.
 *
 * Code is compiled when a symbol in it is first looked up, not by `create`,
 * and the stack map bytes appear only then.
 */
class EcoJIT {
public:
    ~EcoJIT();

    // Builds an engine for `op`, which must be a module in the LLVM dialect.
    //
    // The module is translated to LLVM IR, given packed wrappers, passed to
    // `options.transformer` if one is set, and added to the engine, which
    // targets the host. Symbols the module does not define are resolved
    // against the current process, and against what `registerSymbols` later
    // defines. `op` is not kept. Returns an error if translation fails or
    // no target machine can be made for the host. A transformer that returns
    // an error, or a failure to build the engine, add the module or create
    // the process symbol generator, is not reported: it is treated as
    // impossible, which aborts when assertions are on and is undefined
    // behaviour otherwise.
    static llvm::Expected<std::unique_ptr<EcoJIT>>
    create(mlir::Operation *op, const EcoJITOptions &options = {});

    // Returns the address of the symbol `name`, compiling the code that
    // defines it if it has not been compiled yet.
    //
    // Returns an error if the symbol cannot be found or resolves to null.
    // Compiling may replace the bytes held by `getStackMapData`. This does
    // not run the module's initializers; `invokePacked` does.
    llvm::Expected<void *> lookup(llvm::StringRef name) const;

    // Returns the packed wrapper of the function `name`, as `lookup` does.
    //
    // The wrapper takes an array whose element `i` points to the value of
    // argument `i`, followed, for a function that returns a value, by one
    // more element pointing to where the result is stored. Only functions
    // the translated module defines without local linkage have a wrapper.
    llvm::Expected<void (*)(void **)> lookupPacked(llvm::StringRef name) const;

    // Calls the function `name` through its packed wrapper with `args`,
    // laid out as `lookupPacked` describes.
    //
    // Runs the module's initializers first, on the first call only; a
    // failure in them is not reported (see `initialize`). Returns an error if
    // the wrapper cannot be found. `args` must have an element for every
    // argument and, for a function that returns a value, for the result;
    // nothing checks this.
    llvm::Error invokePacked(llvm::StringRef name,
                             llvm::MutableArrayRef<void *> args = {});

    // Defines, in the engine's main library, the absolute symbols that
    // `symbolMap` returns when called with the engine's name mangler.
    //
    // `symbolMap` is called once, before this returns. Defining a name that
    // is already defined is not reported: it is treated as impossible, which
    // aborts when assertions are on and is undefined behaviour otherwise.
    void registerSymbols(
        llvm::function_ref<llvm::orc::SymbolMap(llvm::orc::MangleAndInterner)>
            symbolMap);

    // Sets the data layout and target triple of `llvmModule` to those of
    // `tm`. Neither may be null.
    static void setupTargetTripleAndDataLayout(llvm::Module *llvmModule,
                                               llvm::TargetMachine *tm);

    // Returns the stack map bytes of the most recently loaded object that had
    // a stack map section.
    //
    // Empty until a lookup has compiled code. The reference is valid for the
    // engine's lifetime, but a later compilation may replace the contents,
    // which invalidates any pointer taken from `data()`.
    const StackMapData &getStackMapData() const { return stackMapData_; }

private:
    // Creates an empty engine; `create` fills it in.
    EcoJIT();

    // Runs the module's initializers if they have not run yet. A failure is
    // not reported: it is treated as impossible, which aborts when assertions
    // are on and is undefined behaviour otherwise.
    void initialize();

    std::unique_ptr<llvm::orc::LLJIT> jit_;

    // Written by `stackMapListener_` whenever an object that has a stack map
    // section is loaded, including during a `const` lookup.
    StackMapData stackMapData_;

    // The listener that fills `stackMapData_`. The object layer inside
    // `jit_` holds a reference to it without owning it, so `jit_` must be
    // destroyed first. It holds a reference to `stackMapData_`.
    class StackMapListener;
    std::unique_ptr<StackMapListener> stackMapListener_;

    // Whether `initialize` has run the module's initializers.
    bool isInitialized_ = false;
};

} // namespace eco

#endif // ECO_JIT_H
