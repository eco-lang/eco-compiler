//===- ecogen.cpp - Eco dialect code generation tool ----------------------===//
//
// This is the main entry point for the Eco code generation tool. It parses
// an MLIR file containing the Eco dialect, verifies it, and prints it to
// stdout.
//
// Usage: ecogen <input.mlir>
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
// Command line options
static llvm::cl::opt<std::string> inputFilename(
    llvm::cl::Positional,
    llvm::cl::desc("<input .mlir file>"),
    llvm::cl::Required);

static llvm::cl::opt<std::string> outputFilename(
    "o",
    llvm::cl::desc("Output filename (default: stdout)"),
    llvm::cl::value_desc("filename"),
    llvm::cl::init("-"));

static llvm::cl::opt<bool> verifyOnly(
    "verify-only",
    llvm::cl::desc("Only verify the input, don't print output"),
    llvm::cl::init(false));

static llvm::cl::opt<bool> printDebugInfo(
    "mlir-print-debuginfo",
    llvm::cl::desc("Print debug info in MLIR output"),
    llvm::cl::init(false));

} // namespace

/// Load and parse an MLIR file, returning the module if successful.
static OwningOpRef<ModuleOp> loadMLIR(MLIRContext &context,
                                       llvm::SourceMgr &sourceMgr) {
  // Parse the input file.
  auto module = parseSourceFile<ModuleOp>(sourceMgr, &context);
  if (!module) {
    llvm::errs() << "Error: Failed to parse MLIR file\n";
    return nullptr;
  }
  return module;
}

int main(int argc, char **argv) {
  // Initialize LLVM infrastructure
  llvm::InitLLVM initLLVM(argc, argv);

  // Parse command line arguments
  llvm::cl::ParseCommandLineOptions(argc, argv,
      "Eco dialect code generation tool\n\n"
      "This tool parses MLIR files containing the Eco dialect,\n"
      "verifies them, and prints the output.\n");

  // Create the MLIR context and register dialects
  MLIRContext context;

  // Register the Eco dialect
  context.getOrLoadDialect<eco::EcoDialect>();

  // Register the func dialect (used for function definitions)
  context.getOrLoadDialect<func::FuncDialect>();

  // Allow unregistered dialects for flexibility during development
  context.allowUnregisteredDialects();

  // Set up the source manager with the input file
  std::string errorMessage;
  auto inputFile = openInputFile(inputFilename, &errorMessage);
  if (!inputFile) {
    llvm::errs() << "Error: " << errorMessage << "\n";
    return 1;
  }

  llvm::SourceMgr sourceMgr;
  sourceMgr.AddNewSourceBuffer(std::move(inputFile), llvm::SMLoc());

  // Parse the MLIR file
  auto module = loadMLIR(context, sourceMgr);
  if (!module) {
    return 1;
  }

  // Verify the module
  if (failed(module->verify())) {
    llvm::errs() << "Error: Module verification failed\n";
    return 1;
  }

  llvm::outs() << "Verification successful!\n";

  // If verify-only mode, exit here
  if (verifyOnly) {
    return 0;
  }

  // Set up the output file
  auto outputFile = openOutputFile(outputFilename, &errorMessage);
  if (!outputFile) {
    llvm::errs() << "Error: " << errorMessage << "\n";
    return 1;
  }

  // Configure printing options
  OpPrintingFlags printFlags;
  if (printDebugInfo) {
    printFlags.enableDebugInfo();
  }

  // Print the module to output
  module->print(outputFile->os(), printFlags);
  outputFile->os() << "\n";

  // Keep the output file
  outputFile->keep();

  return 0;
}
