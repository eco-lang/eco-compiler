//===- EcoNativeDriver.h - Library API for MLIR-to-native lowering -------===//
//
// A program written in Elm is compiled to eco-dialect MLIR, and something has
// to turn that MLIR into a binary that runs. This component is that step, as a
// library, so that any program linking it can produce a native binary without
// starting the compiler's own driver.
//
// It does two things. It lowers: it reads MLIR (text or bytecode, from a file
// or from memory), runs the Eco pass pipeline (`buildEcoToLLVMPipeline`),
// translates the result to LLVM IR and hands it to the LLVM backend
// (`runEcoBackend`), which writes one or more object files. It links: it runs
// a linker as a child process to combine those objects with the runtime and
// kernel archives into the output. Lowering happens in the calling process;
// linking always starts another process.
//
// What the compile entry points produce depends only on the extension of the
// output path. `.o` is a relocatable object file and nothing is linked.
// `.so` and `.node` are shared libraries, linked with the embedding entry point instead of a
// `main()`; a `.node` file also gets the Node.js addon glue and a CommonJS
// loader written beside it. Anything else is an executable, linked with the
// standalone entry point. Only an executable is closed-world: nothing outside
// the binary can call into it, so the lowering may internalize and delete
// every function that `main` and `__eco_init_globals` cannot reach, and may
// split the program into partitions lowered on separate threads.
//
// How the link is done is decided per platform: a direct invocation of
// `ld.lld` or the configured system linker on Linux, the clang driver on
// macOS, and clang-cl with lld-link on Windows. Shared-library output is
// supported only on Linux.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_NATIVE_DRIVER_H
#define ECO_NATIVE_DRIVER_H

#include <string>
#include <vector>

namespace eco {

class LoweringStats;

/// The settings for one lowering and link, apart from the input and output
/// paths.
///
/// A default-constructed `EcoNativeOptions` gives an -O2 build with the
/// partition count and parallel-optimization tier chosen automatically. The
/// numeric fields stand for LLVM and backend enumerations and are kept as
/// plain integers so that this header does not include LLVM; nothing checks
/// that a value is in range.
struct EcoNativeOptions {
    /// The LLVM optimization level, 0 to 3. A value above 3 is treated as 3.
    unsigned optLevel = 2;

    /// The requested number of partitions to emit in parallel: 0 for
    /// automatic, 1 for none, or an explicit count, with the meaning
    /// `EcoBackendJob::splitCodegen` gives it. Applies to executable output
    /// only.
    unsigned splitCodegen = 0;

    /// The parallel-optimization tier: 1 for `ParallelOpt::Dev`, 2 for
    /// `ParallelOpt::Cgu`, and any other value for `ParallelOpt::None`.
    /// Applies to executable output only.
    unsigned parallelOpt = 2;

    /// Under the Dev tier, the codegen level that
    /// `EcoBackendJob::devEmitCodeGenLevel` describes: 0 None, 1 Less,
    /// 2 Default, or `~0u` to follow `optLevel`.
    unsigned devEmitCodeGenLevel = ~0u;

    /// Under the Dev tier, run the per-partition optimization at O1.
    bool devOptO1 = false;

    /// Write progress lines, including the linker command line, to standard
    /// error.
    bool verbose = false;

    /// Where to write the LLVM IR as text before RS4GC; empty for no dump.
    std::string preRS4GCDumpPath;
    /// Where to write the LLVM IR as text after RS4GC; empty for no dump.
    std::string postRS4GCDumpPath;

    /// The name of the program's root Elm module, stored in a shared-library
    /// output as the symbol `__eco_root_module`. Empty means the symbol is not
    /// created. Executables and object files ignore it.
    std::string rootModule;

    /// Where to record the time of each phase, or null for no timing. It is
    /// written during the call and never printed here, and must outlive the
    /// call.
    LoweringStats *stats = nullptr;

    /// Whether to link an executable with `--gc-sections`, to drop unused
    /// sections from the linked archives. The linker would otherwise discard
    /// `.llvm_stackmaps`, which nothing refers to but which the collector
    /// needs to find stack roots, so a linker script that keeps it is added
    /// as well; if that script cannot be written, a warning is printed and
    /// `--gc-sections` is not used. Honoured only by the Linux link and not
    /// for shared libraries.
    bool gcSections = false;
};

/// Registers LLVM's native target, assembly printer and assembly parser.
///
/// Calls after the first return at once. The flag that records the first
/// call is not synchronized, so two threads must not make the first call at
/// the same time.
void initializeLLVMNativeTarget();

/// Lowers the MLIR in the file at `mlirPath` and links it at `outputPath`, as
/// the file comment describes. Returns 0 on success and 1 on failure, with
/// the reason written to standard error.
///
/// The file may hold MLIR text or bytecode. The call registers the native
/// target and creates its own MLIRContext, which lives until it returns.
int compileMlirFileToExecutable(const std::string &mlirPath,
                                const std::string &outputPath,
                                const EcoNativeOptions &opts);

/// Lowers the `mlirLen` bytes of MLIR at `mlirBytes` and links them at
/// `outputPath`, as `compileMlirFileToExecutable` does for a file. The bytes
/// are read only during the call.
int compileMlirBytesToExecutable(const char *mlirBytes, size_t mlirLen,
                                  const std::string &outputPath,
                                  const EcoNativeOptions &opts);

/// Links the object file `objectFile` with the runtime and kernel archives
/// into `outputPath`, as the vector overload does for one object.
int linkExecutable(const std::string &objectFile,
                   const std::string &outputPath,
                   const EcoNativeOptions &opts,
                   bool sharedLib = false);

/// Links `objectFiles` with the runtime and kernel archives into an
/// executable at `outputPath`, or into a shared library when `sharedLib` is
/// true. Returns 0 on success and 1 on failure, with the reason written to
/// standard error.
///
/// The linker runs as a child process and the call waits for it. A shared
/// library is linked with the embedding entry point in place of `main()`,
/// and, when `outputPath` ends in `.node`, with the Node.js addon glue and a
/// CommonJS loader written next to it with the extension `.js`. On macOS and
/// Windows a shared library is refused. The object files are not deleted.
int linkExecutable(const std::vector<std::string> &objectFiles,
                   const std::string &outputPath,
                   const EcoNativeOptions &opts,
                   bool sharedLib = false);

} // namespace eco

#endif // ECO_NATIVE_DRIVER_H
