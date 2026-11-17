/// \file MaxVerify.cpp
/// See MaxVerify.hpp.
#include "MaxVerify.hpp"

#include "mlir/Bytecode/BytecodeReader.h"
#include "mlir/IR/BuiltinAttributes.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/Diagnostics.h"
#include "mlir/IR/MLIRContext.h"
#include "mlir/IR/Verifier.h"
#include "mlir/Parser/Parser.h"

#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/SourceMgr.h"

namespace eco::max {
namespace {

/// An attribute of `op` by name: a plain (discardable) attribute, or for an op eco's MLIR does not
/// know, an entry of its properties dictionary.
mlir::Attribute lookup(mlir::Operation *op, llvm::StringRef name) {
    if (mlir::Attribute a = op->getDiscardableAttr(name))
        return a;
    if (auto props = llvm::dyn_cast_or_null<mlir::DictionaryAttr>(op->getPropertiesAsAttribute()))
        return props.get(name);
    return {};
}

/// The number of strings in a names attribute, or -1 if it is not an array of strings.
int64_t nameCount(mlir::Attribute a) {
    auto array = llvm::dyn_cast_or_null<mlir::ArrayAttr>(a);
    if (!array)
        return -1;
    for (mlir::Attribute e : array)
        if (!llvm::isa<mlir::StringAttr>(e))
            return -1;
    return int64_t(array.size());
}

std::string checkGraph(mlir::ModuleOp module, bool bytecode) {
    mlir::Operation *graph = nullptr;
    for (mlir::Operation &op : module.getBody()->getOperations()) {
        if (op.getName().getStringRef() != "mo.graph")
            return "the module holds a " + op.getName().getStringRef().str() +
                   "; MAX takes a module of exactly one mo.graph";
        if (graph)
            return "the module holds more than one mo.graph";
        graph = &op;
    }
    if (!graph)
        return "the module holds no mo.graph";
    if (!llvm::isa_and_nonnull<mlir::StringAttr>(lookup(graph, "sym_name")))
        return "the mo.graph has no sym_name";
    if (graph->getNumRegions() != 1 || graph->getRegion(0).empty())
        return "the mo.graph has no body";
    const int64_t args = int64_t(graph->getRegion(0).front().getNumArguments());
    const int64_t argNames = nameCount(lookup(graph, "argument_names"));
    if (argNames != args)
        return "the mo.graph's argument_names " +
               (argNames < 0 ? std::string("are missing or not strings")
                             : "name " + std::to_string(argNames) + " arguments, but it has " +
                                   std::to_string(args));
    if (nameCount(lookup(graph, "result_names")) < 0)
        return "the mo.graph's result_names are missing or not strings";

    if (bytecode) {
        std::string offender;
        module.walk([&](mlir::Operation *op) {
            if (op->getName().isRegistered())
                return mlir::WalkResult::advance();
            auto props = llvm::dyn_cast_or_null<mlir::DictionaryAttr>(op->getPropertiesAsAttribute());
            if (props && !props.empty()) {
                offender = op->getName().getStringRef().str();
                return mlir::WalkResult::interrupt();
            }
            return mlir::WalkResult::advance();
        });
        if (!offender.empty())
            return "in bytecode, " + offender +
                   " carries MLIR properties, which MAX cannot read (and crashes on); write them "
                   "as plain attributes";
    }
    return "";
}

} // namespace

std::string verifyModule(const std::filesystem::path &file) {
    auto buffer = llvm::MemoryBuffer::getFile(file.string(), /*IsText=*/false);
    if (!buffer)
        return "cannot read " + file.string() + ": " + buffer.getError().message();
    const bool bytecode = mlir::isBytecode((*buffer)->getMemBufferRef());

    mlir::MLIRContext context(mlir::MLIRContext::Threading::DISABLED);
    context.allowUnregisteredDialects();
    std::string diagnostics;
    mlir::ScopedDiagnosticHandler handler(&context, [&](mlir::Diagnostic &d) {
        if (d.getSeverity() == mlir::DiagnosticSeverity::Error)
            diagnostics += (diagnostics.empty() ? "" : "; ") + d.str();
        return mlir::success();
    });

    llvm::SourceMgr sources;
    sources.AddNewSourceBuffer(std::move(*buffer), llvm::SMLoc());
    mlir::OwningOpRef<mlir::ModuleOp> module =
        mlir::parseSourceFile<mlir::ModuleOp>(sources, mlir::ParserConfig(&context));
    if (!module)
        return file.string() + " is not MLIR eco can read" +
               (diagnostics.empty() ? std::string() : ": " + diagnostics);
    if (mlir::failed(mlir::verify(*module)))
        return file.string() + " fails MLIR verification" +
               (diagnostics.empty() ? std::string() : ": " + diagnostics);
    std::string problem = checkGraph(*module, bytecode);
    return problem.empty() ? problem : file.string() + ": " + problem;
}

} // namespace eco::max
