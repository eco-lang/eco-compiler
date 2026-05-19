//===- EcoBackend.cpp - Shared Eco LLVM backend helpers -------------------===//

#include "EcoBackend.h"

#include "Passes/EcoPtrIntVerify.h" // for addEcoGCPipeline

#include "llvm/IR/Function.h"
#include "llvm/IR/Module.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/Support/ErrorHandling.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/raw_ostream.h"

using namespace llvm;

namespace eco {

namespace {

void dumpIRTo(const Module &m, const std::string &path, const char *tag) {
    std::error_code ec;
    raw_fd_ostream out(path, ec);
    if (!ec) {
        out << m;
        errs() << "[" << tag << "] Dumped " << tag << " IR to " << path
               << "\n";
    } else {
        errs() << "[" << tag << "] Error: could not open " << path << ": "
               << ec.message() << "\n";
    }
}

} // namespace

void runRS4GCAndMaybeFramePointers(Module &m, const RS4GCOptions &opts) {
    if (!opts.preDumpPath.empty())
        dumpIRTo(m, opts.preDumpPath, "pre-rs4gc");

    // RS4GC pipeline: inserts gc.statepoint/gc.relocate for all
    // GC-triggering calls in functions with gc "eco-gc".
    LoopAnalysisManager LAM;
    FunctionAnalysisManager FAM;
    CGSCCAnalysisManager CGAM;
    ModuleAnalysisManager MAM;
    PassBuilder PB;
    PB.registerModuleAnalyses(MAM);
    PB.registerCGSCCAnalyses(CGAM);
    PB.registerFunctionAnalyses(FAM);
    PB.registerLoopAnalyses(LAM);
    PB.crossRegisterProxies(LAM, FAM, CGAM, MAM);

    ModulePassManager MPM;
    addEcoGCPipeline(MPM);
    MPM.run(m, MAM);

    if (!opts.postDumpPath.empty())
        dumpIRTo(m, opts.postDumpPath, "rs4gc");

    // Force frame pointers so libunwind can walk JIT/AOT frames for GC root
    // discovery.
    if (opts.addFramePointerAttr) {
        for (Function &F : m) {
            if (!F.isDeclaration())
                F.addFnAttr("frame-pointer", "all");
        }
    }
}

Error runEcoBackend(Module &m, const EcoBackendJob &job) {
    RS4GCOptions rs4gcOpts;
    rs4gcOpts.preDumpPath = job.preRS4GCDumpPath;
    rs4gcOpts.postDumpPath = job.postRS4GCDumpPath;
    rs4gcOpts.addFramePointerAttr = job.needsFramePointerAttr;
    runRS4GCAndMaybeFramePointers(m, rs4gcOpts);

    switch (job.kind) {
    case BackendKind::DumpLLVMText:
    case BackendKind::EmitObjectFile:
        // Phase 2 façade: RS4GC + FP only. Phase 3.3 expands EmitObjectFile to
        // drive opt + object emission + exe link.
        return Error::success();

    case BackendKind::JITInvokePacked:
        // Reserved for Phase 4. No caller constructs this kind yet.
        llvm_unreachable("BackendKind::JITInvokePacked is reserved for Phase 4");
    }

    llvm_unreachable("Unknown BackendKind");
}

} // namespace eco
