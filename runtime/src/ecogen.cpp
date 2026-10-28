//===- ecogen.cpp - Eco dialect parse-and-verify tool ---------------------===//
//
// A standalone tool for checking an `.mlir` file against the Eco dialect's verifiers,
// without running any pass or code generation.
//
// It parses one module, runs MLIR's verifier over it, and prints the module back.
// Only the eco and func dialects are loaded, besides MLIR's builtin dialect. Unregistered dialects are
// allowed, so an operation from any other dialect is accepted as an opaque,
// unverified operation, provided it is written in MLIR's generic form.
//
// Usage: ecogen <input.mlir> [-o <file>] [--verify-only] [--mlir-print-debuginfo]
//
// The exit status is 1 if the input cannot be opened or parsed, the module fails
// verification, or the output file cannot be opened, and 0 otherwise.
//
//===----------------------------------------------------------------------===//

#include "mlir/IR/MLIRContext.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/OwningOpRef.h"
#include "mlir/Parser/Parser.h"
#include "mlir/Support/FileUtilities.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"

#include "llvm/Support/CommandLine.h"
#include "llvm/Support/InitLLVM.h"
#include "llvm/Support/SourceMgr.h"
#include "llvm/Support/ToolOutputFile.h"
#include "llvm/Support/raw_ostream.h"

#include "codegen/EcoDialect.h"
#include "codegen/EcoOps.h"

using namespace mlir;

namespace {
/// The path of the `.mlir` file to read; `-` reads standard input.
static llvm::cl::opt<std::string> inputFilename(
    llvm::cl::Positional,
    llvm::cl::desc("<input .mlir file>"),
    llvm::cl::Required);

/// The path the module is printed to (`-o`); `-`, the default, is standard output.
static llvm::cl::opt<std::string> outputFilename(
    "o",
    llvm::cl::desc("Output filename (default: stdout)"),
    llvm::cl::value_desc("filename"),
    llvm::cl::init("-"));

/// Whether to stop after verification without printing the module (`--verify-only`).
static llvm::cl::opt<bool> verifyOnly(
    "verify-only",
    llvm::cl::desc("Only verify the input, don't print output"),
    llvm::cl::init(false));

/// Whether the printed module carries its source locations (`--mlir-print-debuginfo`).
static llvm::cl::opt<bool> printDebugInfo(
    "mlir-print-debuginfo",
    llvm::cl::desc("Print debug info in MLIR output"),
    llvm::cl::init(false));

} // namespace

/// Parses the buffers in `sourceMgr` as a module in `context`, and returns it, or a
/// null `OwningOpRef` after writing an error line to standard error if parsing fails.
/// The module does not outlive `context`.
static OwningOpRef<ModuleOp> loadMLIR(MLIRContext &context,
                                       llvm::SourceMgr &sourceMgr) {
  auto module = parseSourceFile<ModuleOp>(sourceMgr, &context);
  if (!module) {
    llvm::errs() << "Error: Failed to parse MLIR file\n";
    return nullptr;
  }
  return module;
}

/// Reads, verifies and prints the module named on the command line, as the file
/// comment describes. "Verification successful!" is written to standard output
/// before the module is printed, so with the default `-o -` it precedes the module
/// in the same stream.
int main(int argc, char **argv) {
  llvm::InitLLVM initLLVM(argc, argv);

  llvm::cl::ParseCommandLineOptions(argc, argv,
      "Eco dialect code generation tool\n\n"
      "This tool parses MLIR files containing the Eco dialect,\n"
      "verifies them, and prints the output.\n");

  MLIRContext context;
  context.getOrLoadDialect<eco::EcoDialect>();
  context.getOrLoadDialect<func::FuncDialect>();

  // Operations of any dialect not loaded above parse as unregistered operations,
  // which the verifier does not check.
  context.allowUnregisteredDialects();

  std::string errorMessage;
  auto inputFile = openInputFile(inputFilename, &errorMessage);
  if (!inputFile) {
    llvm::errs() << "Error: " << errorMessage << "\n";
    return 1;
  }

  llvm::SourceMgr sourceMgr;
  sourceMgr.AddNewSourceBuffer(std::move(inputFile), llvm::SMLoc());

  auto module = loadMLIR(context, sourceMgr);
  if (!module) {
    return 1;
  }

  if (failed(module->verify())) {
    llvm::errs() << "Error: Module verification failed\n";
    return 1;
  }

  llvm::outs() << "Verification successful!\n";

  if (verifyOnly) {
    return 0;
  }

  auto outputFile = openOutputFile(outputFilename, &errorMessage);
  if (!outputFile) {
    llvm::errs() << "Error: " << errorMessage << "\n";
    return 1;
  }

  OpPrintingFlags printFlags;
  if (printDebugInfo) {
    printFlags.enableDebugInfo();
  }

  module->print(outputFile->os(), printFlags);
  outputFile->os() << "\n";

  outputFile->keep();

  return 0;
}
