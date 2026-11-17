/// \file MaxSmokeTest.cpp
/// max-smoke-test: eco's MAX dependency works end to end (plans/llvm-24-upgrade.md §5.5).
///
/// It loads the MAX that deps/max/ pins through eco::max::load (checking its version), and:
///   - compiles and runs graph.mlir (out = in0 x in1 + in0, 2x2 f32) from generic text and from
///     bytecode eco's MLIR writes, checking the numbers, after eco::max::verifyModule passes it;
///   - checks verifyModule refuses what would crash MAX or is not a MAX graph: bytecode whose MAX
///     ops carry MLIR properties (graph-properties.mlir written by eco's MLIR), truncated
///     bytecode, text that is not MLIR, and a graph without argument names. None of those reach
///     MAX.
///
///   max-smoke-test [FIXTURE_DIR]      (run-max-smoke builds and runs it)
///
/// Exits non-zero, after running every check, if any fails.
#include "MaxLoader.hpp"
#include "MaxVerify.hpp"

#include "mlir/Bytecode/BytecodeWriter.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/MLIRContext.h"
#include "mlir/Parser/Parser.h"

#include "llvm/Support/raw_ostream.h"

#include <unistd.h>

#include <array>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

namespace fs = std::filesystem;
using namespace eco::max;

namespace {

int failures = 0;

void report(bool ok, const std::string &what, const std::string &detail = "") {
    std::printf("%s %s%s%s\n", ok ? "PASS" : "FAIL", what.c_str(), detail.empty() ? "" : ": ",
                detail.c_str());
    std::fflush(stdout);
    if (!ok)
        ++failures;
}

/// Writes `text` (generic MLIR) as bytecode with eco's MLIR, as an eco producer would.
bool writeBytecode(const fs::path &text, const fs::path &out) {
    mlir::MLIRContext context;
    context.allowUnregisteredDialects();
    auto module = mlir::parseSourceFile<mlir::ModuleOp>(text.string(), &context);
    if (!module)
        return false;
    std::error_code ec;
    llvm::raw_fd_ostream os(out.string(), ec);
    return !ec && mlir::succeeded(mlir::writeBytecodeToFile(*module, os));
}

void writeFile(const fs::path &path, const std::string &bytes) {
    std::ofstream(path, std::ios::binary) << bytes;
}

std::string readFile(const fs::path &path) {
    std::ifstream in(path, std::ios::binary);
    return {std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>()};
}

/// MAX state shared by every run: one runtime context on the host CPU.
struct Engine {
    const Api *m;
    M_Device *host = nullptr;
    M_RuntimeContext *context = nullptr;
};

/// Compiles `graph` and runs it on fixed inputs; returns "" when out = in0 x in1 + in0.
std::string compileAndRun(const Engine &e, const fs::path &graph) {
    const Api &m = *e.m;
    M_Status *st = m.M_newStatus();
    std::string error;
    auto failed = [&](const char *step) {
        if (!m.M_isError(st))
            return false;
        const char *why = m.M_getError(st);
        error = std::string(step) + ": " + (why && *why ? why : "MAX gave no error text");
        return true;
    };

    M_CompileConfig *config = m.M_newCompileConfig();
    m.M_setModelPath(config, graph.c_str());
    M_AsyncCompiledModel *compiled = m.M_compileModelSync(e.context, &config, st);
    M_AsyncModel *model = nullptr;
    if (!failed("compile")) {
        model = m.M_initModel(e.context, compiled, nullptr, st);
        if (!failed("init"))
            m.M_waitForModel(model, st);
    }
    if (error.empty() && !failed("init")) {
        int64_t shape[2] = {2, 2};
        std::array<float, 4> a{1, 2, 3, 4}, b{5, 6, 7, 8};
        M_TensorSpec *sa = m.M_newTensorSpec(shape, 2, M_FLOAT32, "input0", e.host);
        M_TensorSpec *sb = m.M_newTensorSpec(shape, 2, M_FLOAT32, "input1", e.host);
        M_AsyncTensorMap *inputs = m.M_newAsyncTensorMap(e.context);
        m.M_borrowTensorInto(inputs, a.data(), sa, st);
        m.M_borrowTensorInto(inputs, b.data(), sb, st);
        M_AsyncTensorMap *outputs = nullptr;
        if (!failed("inputs"))
            outputs = m.M_executeModelSync(e.context, model, inputs, st);
        if (outputs && !failed("run")) {
            M_AsyncTensor *out = m.M_getTensorByNameFrom(outputs, "output0", st);
            if (!failed("output0")) {
                const auto *r = static_cast<const float *>(m.M_getTensorData(out));
                const std::array<float, 4> want{20, 24, 46, 54};
                for (size_t i = 0; i < 4; ++i)
                    if (std::fabs(r[i] - want[i]) > 1e-4f)
                        error = "output0[" + std::to_string(i) + "] = " + std::to_string(r[i]) +
                                ", expected " + std::to_string(want[i]);
                m.M_freeTensor(out);
            }
        }
        if (outputs)
            m.M_freeAsyncTensorMap(outputs);
        m.M_freeAsyncTensorMap(inputs);
        m.M_freeTensorSpec(sa);
        m.M_freeTensorSpec(sb);
    }
    if (model)
        m.M_freeModel(model);
    if (compiled)
        m.M_freeCompiledModel(compiled);
    m.M_freeStatus(st);
    return error;
}

/// The verified path eco uses: check first, and only a module that passes reaches MAX.
void expectRuns(const Engine &e, const fs::path &graph, const std::string &what) {
    const std::string problem = verifyModule(graph);
    if (!problem.empty()) {
        report(false, what, "refused: " + problem);
        return;
    }
    report(true, what + " passes the check");
    const std::string error = compileAndRun(e, graph);
    report(error.empty(), what + " compiles and computes in0 x in1 + in0", error);
}

void expectRefused(const fs::path &graph, const std::string &what) {
    const std::string problem = verifyModule(graph);
    report(!problem.empty(), what + " is refused before MAX sees it",
           problem.empty() ? "it passed the check" : problem);
}

} // namespace

int main(int argc, char **argv) {
    const fs::path fixtures = argc > 1 ? fs::path(argv[1]) : fs::path(ECO_MAX_FIXTURES);
    const fs::path work = fs::temp_directory_path() / ("eco-max-smoke-" + std::to_string(::getpid()));
    fs::create_directories(work);

    std::string error;
    const Api *api = load({ECO_MAX_PACKAGE_ROOT, ECO_MAX_VERSION}, error);
    report(api != nullptr, std::string("MAX ") + ECO_MAX_VERSION + " loads from " + ECO_MAX_PACKAGE_ROOT,
           error);
    if (!api)
        return 1;

    Engine e{api};
    {
        M_Status *st = api->M_newStatus();
        M_RuntimeConfig *config = api->M_newRuntimeConfig();
        e.host = api->M_newDevice(M_HOST, 0, st);
        api->M_runtimeConfigAddDevice(config, e.host);
        e.context = api->M_newRuntimeContext(config, st);
        const bool ok = !api->M_isError(st);
        report(ok, "MAX runtime context on the host CPU", ok ? "" : api->M_getError(st));
        api->M_freeStatus(st);
        if (!ok)
            return 1;
    }

    const fs::path text = fixtures / "graph.mlir";
    const fs::path bytecode = work / "graph.mlirbc";
    const fs::path propsBytecode = work / "graph-properties.mlirbc";
    report(writeBytecode(text, bytecode), "eco's MLIR writes graph.mlir as bytecode");
    report(writeBytecode(fixtures / "graph-properties.mlir", propsBytecode),
           "eco's MLIR writes graph-properties.mlir as bytecode");

    expectRuns(e, text, "graph.mlir (generic text)");
    expectRuns(e, bytecode, "graph.mlir as eco-written bytecode");
    expectRuns(e, fixtures / "graph-properties.mlir", "graph-properties.mlir (text with properties)");

    expectRefused(propsBytecode, "eco-written bytecode whose MAX ops carry properties");
    const std::string whole = readFile(bytecode);
    writeFile(work / "truncated.mlirbc", whole.substr(0, whole.size() / 2));
    expectRefused(work / "truncated.mlirbc", "truncated bytecode");
    writeFile(work / "not-mlir.mlir", "this is not MLIR\n");
    expectRefused(work / "not-mlir.mlir", "text that is not MLIR");
    std::string unnamed = readFile(text);
    const std::string names = "argument_names = [\"input0\", \"input1\"], ";
    const size_t at = unnamed.find(names);
    report(at != std::string::npos, "graph.mlir has the argument_names this test removes");
    if (at != std::string::npos) {
        unnamed.erase(at, names.size());
        writeFile(work / "unnamed.mlir", unnamed);
        expectRefused(work / "unnamed.mlir", "a graph without argument_names");
    }

    api->M_freeRuntimeContext(e.context);
    std::error_code ec;
    fs::remove_all(work, ec);
    std::printf("%s: %d failure(s)\n", failures ? "FAILED" : "OK", failures);
    return failures ? 1 : 0;
}
