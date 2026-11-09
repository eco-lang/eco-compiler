// A generic MAX host for an eco program: it knows nothing about MNIST or neural networks.
//
// Ports (see src/Bridge.elm for the byte layout):
//   compileOut (bytes)  [header id] "in name:dtype:AxB ...\nout name:dtype:AxB ...\n" mlir text
//                       -> compiled on a worker thread; the answer goes to compiledIn as JSON
//   runOut (bytes)      [header id] inputs, each padded to 16 bytes
//                       -> executed on the eco thread with the inputs borrowed in place from the
//                          Elm heap; outputs emitted on runIn as [header id] outputs, padded to 16
//   loadOut (bytes)     [header id] path -> the file's bytes on loadIn as [header id] contents
//   logOut (string)     printed with the time since start
//   doneOut (int)       stops the program with that exit code
//
//   max_bridge WORKDIR '{"dataDir": "..."}'
//
// ECO_MAX_THREADS=N sizes MAX's CPU worker pool; ECO_MAX_BUSY_WAIT_US=T is how long an idle worker
// spins before it sleeps (MAX's default: 200 µs, on every core).
#include <eco/eco_embed.hpp>

#include "max/c/common.h"
#include "max/c/context.h"
#include "max/c/device.h"
#include "max/c/model.h"
#include "max/c/tensor.h"
#include "max/c/types.h"

#include <sched.h>

#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <map>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

namespace {

using Clock = std::chrono::steady_clock;
const Clock::time_point start = Clock::now();

double secs() { return std::chrono::duration<double>(Clock::now() - start).count(); }

double msSince(Clock::time_point t0) {
  return std::chrono::duration<double, std::milli>(Clock::now() - t0).count();
}

struct Spec {
  std::string name;
  M_Dtype dtype;
  size_t elemSize;
  std::vector<int64_t> shape;
  size_t bytes() const {
    size_t n = elemSize;
    for (int64_t d : shape)
      n *= size_t(d);
    return n;
  }
};

struct Graph {
  M_AsyncCompiledModel *compiled = nullptr;
  M_AsyncModel *model = nullptr;
  std::vector<Spec> inputs, outputs;
  std::vector<M_TensorSpec *> inputSpecs;
  int runs = 0;
  double execMs = 0, callbackMs = 0;
};

std::string workDir;
M_RuntimeContext *ctx;
M_Device *host;
std::mutex graphsMutex;
std::map<uint32_t, Graph> graphs;
std::vector<std::thread> compilers;

std::mutex doneMutex;
std::condition_variable doneChanged;
bool finished = false;
int exitCode = 0;

size_t padded(size_t n) { return (n + 15) / 16 * 16; }

uint32_t headerId(const std::byte *p) {
  uint32_t id;
  std::memcpy(&id, p, 4);
  return id;
}

void writeHeader(std::byte *p, uint32_t id) {
  std::memset(p, 0, 16);
  std::memcpy(p, &id, 4);
}

// "in x:ui8:100x784 y:ui8:100" -> specs
std::vector<Spec> parseSpecs(const std::string &line) {
  std::vector<Spec> out;
  std::istringstream words(line);
  std::string word;
  words >> word; // "in" / "out"
  while (words >> word) {
    Spec s;
    size_t a = word.find(':'), b = word.find(':', a + 1);
    s.name = word.substr(0, a);
    std::string dt = word.substr(a + 1, b - a - 1);
    if (dt == "f32")
      s.dtype = M_FLOAT32, s.elemSize = 4;
    else if (dt == "ui8")
      s.dtype = M_UINT8, s.elemSize = 1;
    else if (dt == "si64")
      s.dtype = M_INT64, s.elemSize = 8;
    else
      s.dtype = M_BOOL, s.elemSize = 1;
    std::istringstream dims(word.substr(b + 1));
    std::string d;
    while (std::getline(dims, d, 'x'))
      if (!d.empty())
        s.shape.push_back(std::atoll(d.c_str()));
    out.push_back(s);
  }
  return out;
}

void compileGraph(uint32_t id, std::string text) {
  size_t l1 = text.find('\n'), l2 = text.find('\n', l1 + 1);
  Graph g;
  g.inputs = parseSpecs(text.substr(0, l1));
  g.outputs = parseSpecs(text.substr(l1 + 1, l2 - l1 - 1));
  const std::string path = workDir + "/graph-" + std::to_string(id) + ".mlir";
  std::ofstream(path) << text.substr(l2 + 1);

  auto t0 = Clock::now();
  M_Status *st = M_newStatus();
  M_CompileConfig *cc = M_newCompileConfig();
  M_setModelPath(cc, path.c_str());
  g.compiled = M_compileModelSync(ctx, &cc, st);
  if (!M_isError(st)) {
    g.model = M_initModel(ctx, g.compiled, nullptr, st);
    if (!M_isError(st))
      M_waitForModel(g.model, st);
  }
  const double ms = msSince(t0);
  std::string reply;
  if (M_isError(st)) {
    std::printf("[%7.2fs] HOST compile of graph %u failed: %s\n", secs(), id, M_getError(st));
    reply = "{\"id\":" + std::to_string(id) + ",\"ok\":false}";
  } else {
    std::printf("[%7.2fs] HOST compiled graph %u (%s, %zu bytes of mo text) in %.1f s\n", secs(), id,
                path.c_str(), text.size() - l2 - 1, ms / 1000);
    for (const Spec &s : g.inputs)
      g.inputSpecs.push_back(M_newTensorSpec(s.shape.data(), int64_t(s.shape.size()), s.dtype,
                                             s.name.c_str(), host));
    reply = "{\"id\":" + std::to_string(id) + ",\"ok\":true}";
    std::lock_guard<std::mutex> lock(graphsMutex);
    graphs[id] = std::move(g);
  }
  std::fflush(stdout);
  M_freeStatus(st);
  eco_port_send("compiledIn", reply.c_str()); // any thread may send
}

} // namespace

int main(int argc, char **argv) {
  if (argc < 3) {
    std::fprintf(stderr, "usage: max_bridge WORKDIR FLAGS-JSON\n");
    return 2;
  }
  workDir = argv[1];
  std::filesystem::create_directories(workDir); // compiled graphs are written here
  // MAX reads its worker spin time from two variables, one per CPU-device creation, and aborts if
  // they differ (AsyncRT/lib/Runtime/HostSystem.cpp). ECO_MAX_BUSY_WAIT_US sets both.
  if (const char *us = std::getenv("ECO_MAX_BUSY_WAIT_US")) {
    setenv("MODULAR_THREAD_BUSY_WAIT_US", us, 1);
    setenv("MODULAR_RUNTIME_THREAD_BUSY_WAIT_TIME_US", us, 1);
  }
  M_Status *st = M_newStatus();
  M_RuntimeConfig *rc = M_newRuntimeConfig();
  // MAX sizes its worker pool from this thread's CPU mask when the first device is made, and the
  // workers inherit it. ECO_MAX_THREADS=N narrows the mask to N CPUs for that moment only.
  cpu_set_t saved;
  sched_getaffinity(0, sizeof saved, &saved);
  if (const char *n = std::getenv("ECO_MAX_THREADS")) {
    cpu_set_t narrow;
    CPU_ZERO(&narrow);
    for (int cpu = 0, left = std::atoi(n); cpu < CPU_SETSIZE && left > 0; ++cpu)
      if (CPU_ISSET(cpu, &saved))
        CPU_SET(cpu, &narrow), --left;
    sched_setaffinity(0, sizeof narrow, &narrow);
  }
  host = M_newDevice(M_HOST, 0, st);
  M_runtimeConfigAddDevice(rc, host);
  ctx = M_newRuntimeContext(rc, st);
  if (M_isError(st)) {
    std::printf("HOST context: %s\n", M_getError(st));
    return 1;
  }
  sched_setaffinity(0, sizeof saved, &saved); // the eco thread and the host keep every CPU

  const eco::BytesOutPort compileOut("compileOut");
  const eco::BytesOutPort runOut("runOut");
  const eco::BytesOutPort loadOut("loadOut");
  const eco::BytesInPort runIn("runIn");
  const eco::JsonOutPort logOut("logOut");
  const eco::JsonOutPort doneOut("doneOut");

  eco::Subscription s1 = compileOut.subscribe([](const eco::BorrowedBytes &bytes) {
    std::span<const std::byte> v = bytes.view();
    // The text is copied out: the borrowed bytes are only valid during this call.
    std::string text(reinterpret_cast<const char *>(v.data()) + 16, v.size() - 16);
    compilers.emplace_back(compileGraph, headerId(v.data()), std::move(text));
  });

  eco::Subscription s2 = loadOut.subscribe([](const eco::BorrowedBytes &bytes) {
    std::span<const std::byte> v = bytes.view();
    const uint32_t id = headerId(v.data());
    std::string path(reinterpret_cast<const char *>(v.data()) + 16, v.size() - 16);
    std::ifstream f(path, std::ios::binary | std::ios::ate);
    const size_t n = f ? size_t(f.tellg()) : 0;
    auto *buf = static_cast<uint8_t *>(std::malloc(16 + n));
    writeHeader(reinterpret_cast<std::byte *>(buf), id);
    f.seekg(0);
    f.read(reinterpret_cast<char *>(buf + 16), std::streamsize(n));
    std::printf("[%7.2fs] HOST loaded %s (%zu bytes)\n", secs(), path.c_str(), n);
    std::fflush(stdout);
    eco_port_send_bytes("loadIn", buf, 16 + n, std::free, buf); // lent; released after delivery
  });

  M_Status *rst = M_newStatus();
  eco::Subscription s3 = runOut.subscribe([&runIn, rst](const eco::BorrowedBytes &bytes) {
    auto t0 = Clock::now();
    std::span<const std::byte> v = bytes.view();
    const uint32_t id = headerId(v.data());
    Graph *g;
    {
      std::lock_guard<std::mutex> lock(graphsMutex);
      g = &graphs.at(id);
    }
    // Borrow every input in place: no copy out of the Elm heap, and no GC until we return.
    M_AsyncTensorMap *in = M_newAsyncTensorMap(ctx);
    size_t off = 16;
    for (size_t i = 0; i < g->inputs.size(); ++i) {
      M_borrowTensorInto(in, const_cast<std::byte *>(v.data() + off), g->inputSpecs[i], rst);
      off += padded(g->inputs[i].bytes());
    }
    if (M_isError(rst) || off != v.size()) {
      std::printf("HOST run %u: bad inputs (%zu of %zu bytes): %s\n", id, off, v.size(),
                  M_getError(rst));
      std::exit(1);
    }
    auto t1 = Clock::now();
    M_AsyncTensorMap *outs = M_executeModelSync(ctx, g->model, in, rst);
    if (M_isError(rst)) {
      std::printf("HOST run %u: %s\n", id, M_getError(rst));
      std::exit(1);
    }
    g->execMs += msSince(t1);
    std::vector<M_AsyncTensor *> results;
    size_t total = 16;
    for (const Spec &s : g->outputs) {
      results.push_back(M_getTensorByNameFrom(outs, s.name.c_str(), rst));
      total += padded(s.bytes());
    }
    // One copy: MAX's outputs straight into a new Elm Bytes.
    runIn.emit(total, [&](std::span<std::byte> dst) {
      std::memset(dst.data(), 0, total);
      writeHeader(dst.data(), id);
      size_t o = 16;
      for (size_t i = 0; i < results.size(); ++i) {
        std::memcpy(dst.data() + o, M_getTensorData(results[i]), g->outputs[i].bytes());
        o += padded(g->outputs[i].bytes());
      }
      return total;
    });
    for (M_AsyncTensor *t : results)
      M_freeTensor(t);
    M_freeAsyncTensorMap(outs);
    M_freeAsyncTensorMap(in);
    g->runs++;
    g->callbackMs += msSince(t0);
  });

  eco::Subscription s4 = logOut.subscribe([](std::string_view json) {
    std::printf("[%7.2fs] %.*s\n", secs(), int(json.size()), json.data());
    std::fflush(stdout);
  });

  eco::Subscription s5 = doneOut.subscribe([](std::string_view json) {
    std::lock_guard<std::mutex> lock(doneMutex);
    exitCode = std::atoi(std::string(json).c_str());
    finished = true;
    doneChanged.notify_all();
  });

  if (int rc2 = eco_app_start(1, argv, argv[2]); rc2 != 0) {
    std::printf("HOST eco start failed: %d %s\n", rc2, eco_last_error());
    return 1;
  }
  {
    std::unique_lock<std::mutex> lock(doneMutex);
    doneChanged.wait(lock, [] { return finished; });
  }
  eco_app_stop();
  eco_app_join();
  for (std::thread &t : compilers)
    t.join();
  for (auto &[id, g] : graphs)
    std::printf("HOST graph %u: %d runs, MAX execute %.1f ms total (%.3f ms each), callback %.1f ms total\n",
                id, g.runs, g.execMs, g.runs ? g.execMs / g.runs : 0.0, g.callbackMs);
  std::printf("[%7.2fs] HOST exit %d\n", secs(), exitCode);
  return exitCode;
}
