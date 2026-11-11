// A generic MAX host for an eco program: it knows nothing about MNIST or neural networks.
//
// Ports (see src/Bridge.elm for the byte layout):
//   compileOut (bytes)  [header id] "in name:dtype:AxB[:r=RES] ...\nout name:dtype:AxB[:r=RES] ...\n"
//                       then MLIR, as text or bytecode (told apart by bytecode's magic, "ML\xEFR")
//                       -> compiled on a worker thread; the answer goes to compiledIn as JSON.
//                       `r=RES` marks a resident tensor: an input read from the host buffer RES,
//                       an output that replaces RES after the run (parameters, optimizer state).
//   hostOut (bytes)     the ordered commands, the header's second u32 saying which:
//     1 run             [header id] the fed (non-resident) inputs, each padded to 16 bytes
//                       -> executed on the eco thread with them borrowed in place from the Elm heap
//                          and the resident inputs from the host's buffers; the fed outputs are
//                          emitted on runIn as [header id] outputs, padded to 16
//     2 put             [header] NAME\0 bytes -> the resident buffer NAME
//     3 get             [header id] NAME -> getIn: [header id] the buffer's bytes
//     4 save            [header] NAME\0 PATH -> the buffer written to PATH
//     5 loadInto        [header] NAME\0 PATH -> PATH read into the buffer
//     7 loadRangeInto   [header] NAME\0 offset length PATH -> bytes [offset, offset + length) of PATH
//                       into the buffer (offset, length: each two u32, low then high)
//     8 drop            [header] NAME -> the buffer freed
//     9 loadRange       [header id] offset length PATH -> loadIn: [header id] those bytes
//   Resident buffers stay where a run's outputs left them (no copy), unless MAX placed an output
//   inside an input buffer: that one is copied.
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

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <functional>
#include <span>
#include <fstream>
#include <map>
#include <memory>
#include <utility>
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
  std::string resident; // empty: fed with every run
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
  // bytes crossing the Elm boundary: run messages in (header and fed inputs), replies out
  uint64_t bytesIn = 0, bytesOut = 0, maxIn = 0, maxOut = 0;
  double execMs = 0, callbackMs = 0;
};

std::string workDir;
M_RuntimeContext *ctx;
M_Device *host;
std::mutex graphsMutex;
std::map<uint32_t, Graph> graphs;
// A run's output map, kept alive while any tensor taken from it is resident: such a tensor is
// borrowed from its map (M_getTensorByNameFrom).
struct OutMap {
  M_AsyncTensorMap *map;
  explicit OutMap(M_AsyncTensorMap *m) : map(m) {}
  OutMap(const OutMap &) = delete;
  OutMap &operator=(const OutMap &) = delete;
  ~OutMap() { M_freeAsyncTensorMap(map); }
};

// A resident buffer: parameters, optimizer state, caches that outlive a run. Either a run's output
// tensor, kept where MAX left it (no copy), or bytes the program sent or the host read from a file.
struct Resident {
  std::shared_ptr<OutMap> owner;
  M_AsyncTensor *tensor = nullptr;
  std::vector<std::byte> bytes;
  size_t size = 0;
  Resident() = default;
  Resident(const Resident &) = delete;
  Resident &operator=(const Resident &) = delete;
  Resident(Resident &&o) noexcept
      : owner(std::move(o.owner)), tensor(std::exchange(o.tensor, nullptr)), bytes(std::move(o.bytes)),
        size(o.size) {}
  Resident &operator=(Resident &&o) noexcept {
    if (this != &o) {
      M_freeTensor(tensor);
      owner = std::move(o.owner);
      tensor = std::exchange(o.tensor, nullptr);
      bytes = std::move(o.bytes);
      size = o.size;
    }
    return *this;
  }
  ~Resident() { M_freeTensor(tensor); }
  const std::byte *data() const {
    return tensor ? static_cast<const std::byte *>(M_getTensorData(tensor)) : bytes.data();
  }
  static Resident ofBytes(const void *p, size_t n) {
    Resident r;
    r.bytes.resize(n);
    if (n)
      std::memcpy(r.bytes.data(), p, n);
    r.size = n;
    return r;
  }
};
// Resident buffers by name (eco thread only).
std::map<std::string, Resident> residents;
// Resident outputs MAX placed inside an input buffer, and so copied (they cannot stay in place).
uint64_t aliasedCopies = 0;
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

// "in x:ui8:100x784 y:ui8:100 w:f32:784x128:r=param0" -> specs (a scalar has no dims: "s:f32:")
std::vector<Spec> parseSpecs(const std::string &line) {
  static const std::map<std::string, std::pair<M_Dtype, size_t>> dtypes = {
      {"f16", {M_FLOAT16, 2}}, {"bf16", {M_BFLOAT16, 2}}, {"f32", {M_FLOAT32, 4}},
      {"f64", {M_FLOAT64, 8}}, {"si8", {M_INT8, 1}},      {"si32", {M_INT32, 4}},
      {"si64", {M_INT64, 8}},  {"ui8", {M_UINT8, 1}},     {"ui64", {M_UINT64, 8}},
      {"bool", {M_BOOL, 1}}};
  std::vector<Spec> out;
  std::istringstream words(line);
  std::string word;
  words >> word; // "in" / "out"
  while (words >> word) {
    std::vector<std::string> parts;
    std::string part;
    std::istringstream fields(word);
    while (std::getline(fields, part, ':'))
      parts.push_back(part);
    while (parts.size() < 3)
      parts.push_back("");
    Spec s;
    s.name = parts[0];
    auto dt = dtypes.find(parts[1]);
    if (dt == dtypes.end()) {
      std::printf("HOST unknown dtype %s\n", parts[1].c_str());
      std::fflush(stdout);
      std::_Exit(1);
    }
    s.dtype = dt->second.first;
    s.elemSize = dt->second.second;
    std::istringstream dims(parts[2]);
    std::string d;
    while (std::getline(dims, d, 'x'))
      if (!d.empty())
        s.shape.push_back(std::atoll(d.c_str()));
    if (parts.size() > 3 && parts[3].rfind("r=", 0) == 0)
      s.resident = parts[3].substr(2);
    out.push_back(s);
  }
  return out;
}

void compileGraph(uint32_t id, std::string text) {
  size_t l1 = text.find('\n'), l2 = text.find('\n', l1 + 1);
  Graph g;
  g.inputs = parseSpecs(text.substr(0, l1));
  g.outputs = parseSpecs(text.substr(l1 + 1, l2 - l1 - 1));
  // MAX reads text or bytecode from the file alike; the extension only says which it is.
  const std::string mlir = text.substr(l2 + 1);
  const bool bytecode = mlir.compare(0, 4, "ML\xEFR") == 0;
  const std::string path =
      workDir + "/graph-" + std::to_string(id) + (bytecode ? ".mlirbc" : ".mlir");
  std::ofstream(path, std::ios::binary).write(mlir.data(), std::streamsize(mlir.size()));

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
    std::printf("[%7.2fs] HOST compiled graph %u (%s, %zu bytes of %s) in %.1f s\n", secs(), id,
                path.c_str(), mlir.size(), bytecode ? "MLIR bytecode" : "mo text", ms / 1000);
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
  const eco::BytesOutPort hostOut("hostOut");
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
  auto handleRun = [&runIn, rst](std::span<const std::byte> view) {
    auto t0 = Clock::now();
    std::span<const std::byte> v = view;
    const uint32_t id = headerId(v.data());
    Graph *g;
    {
      std::lock_guard<std::mutex> lock(graphsMutex);
      g = &graphs.at(id);
    }
    // Borrow every fed input in place (no copy out of the Elm heap, and no GC until we return) and
    // every resident input from its host buffer.
    M_AsyncTensorMap *in = M_newAsyncTensorMap(ctx);
    std::vector<std::pair<const std::byte *, size_t>> inputRanges;
    size_t off = 16;
    for (size_t i = 0; i < g->inputs.size(); ++i) {
      const Spec &s = g->inputs[i];
      if (!s.resident.empty()) {
        auto r = residents.find(s.resident);
        if (r == residents.end() || r->second.size != s.bytes()) {
          std::printf("HOST run %u: resident %s is %s (%zu bytes wanted)\n", id, s.resident.c_str(),
                      r == residents.end() ? "missing" : "the wrong size", s.bytes());
          std::fflush(stdout);
      std::_Exit(1);
        }
        M_borrowTensorInto(in, const_cast<std::byte *>(r->second.data()), g->inputSpecs[i], rst);
        inputRanges.emplace_back(r->second.data(), s.bytes());
      } else {
        M_borrowTensorInto(in, const_cast<std::byte *>(v.data() + off), g->inputSpecs[i], rst);
        inputRanges.emplace_back(v.data() + off, s.bytes());
        off += padded(s.bytes());
      }
    }
    if (M_isError(rst) || off != v.size()) {
      std::printf("HOST run %u: bad inputs (%zu of %zu bytes): %s\n", id, off, v.size(),
                  M_getError(rst));
      std::fflush(stdout);
      std::_Exit(1);
    }
    auto t1 = Clock::now();
    M_AsyncTensorMap *outs = M_executeModelSync(ctx, g->model, in, rst);
    if (M_isError(rst)) {
      std::printf("HOST run %u: %s\n", id, M_getError(rst));
      std::fflush(stdout);
      std::_Exit(1);
    }
    g->execMs += msSince(t1);
    std::vector<M_AsyncTensor *> results;
    size_t total = 16;
    for (const Spec &s : g->outputs) {
      results.push_back(M_getTensorByNameFrom(outs, s.name.c_str(), rst));
      if (s.resident.empty())
        total += padded(s.bytes());
    }
    // Resident outputs replace their buffers (after the run: the inputs were read). Each stays where
    // MAX put it, its output map kept alive with it, unless MAX placed it inside an input buffer,
    // which the next run may overwrite: then it is copied.
    auto owner = std::make_shared<OutMap>(outs);
    std::vector<std::pair<std::string, Resident>> replaced;
    for (size_t i = 0; i < results.size(); ++i) {
      const Spec &s = g->outputs[i];
      if (s.resident.empty())
        continue;
      const auto *p = static_cast<const std::byte *>(M_getTensorData(results[i]));
      bool aliased = false;
      for (auto [q, n] : inputRanges)
        aliased = aliased || (p < q + n && q < p + s.bytes());
      if (aliased) {
        replaced.emplace_back(s.resident, Resident::ofBytes(p, s.bytes()));
        ++aliasedCopies;
      } else {
        Resident r;
        r.owner = owner;
        r.tensor = std::exchange(results[i], nullptr);
        r.size = s.bytes();
        replaced.emplace_back(s.resident, std::move(r));
      }
    }
    // One copy: MAX's fed outputs straight into a new Elm Bytes.
    runIn.emit(total, [&](std::span<std::byte> dst) {
      std::memset(dst.data(), 0, total);
      writeHeader(dst.data(), id);
      size_t o = 16;
      for (size_t i = 0; i < results.size(); ++i) {
        if (!g->outputs[i].resident.empty())
          continue;
        std::memcpy(dst.data() + o, M_getTensorData(results[i]), g->outputs[i].bytes());
        o += padded(g->outputs[i].bytes());
      }
      return total;
    });
    for (M_AsyncTensor *t : results)
      M_freeTensor(t);
    owner.reset(); // freed here unless a resident output keeps it
    M_freeAsyncTensorMap(in);
    for (auto &[name, r] : replaced)
      residents.insert_or_assign(name, std::move(r));
    g->runs++;
    g->bytesIn += view.size();
    g->bytesOut += total;
    g->maxIn = std::max<uint64_t>(g->maxIn, view.size());
    g->maxOut = std::max<uint64_t>(g->maxOut, total);
    g->callbackMs += msSince(t0);
  };


  // "NAME\0rest" after the 16-byte header
  auto nameAndRest = [](std::span<const std::byte> v) {
    const char *p = reinterpret_cast<const char *>(v.data()) + 16;
    const size_t n = v.size() - 16;
    const size_t z = std::strlen(p) < n ? std::strlen(p) : n;
    return std::make_pair(std::string(p, z), std::string_view(p + std::min(z + 1, n), n - std::min(z + 1, n)));
  };

  auto handlePut = [&](std::span<const std::byte> view) {
    auto [name, rest] = nameAndRest(view);
    residents.insert_or_assign(name, Resident::ofBytes(rest.data(), rest.size()));
  };

  auto fail = [](const std::string &what) {
    std::printf("HOST %s\n", what.c_str());
    std::fflush(stdout);
    std::_Exit(1);
  };

  auto findResident = [&](const std::string &name, const char *command) -> const Resident & {
    auto r = residents.find(name);
    if (r == residents.end())
      fail(std::string(command) + ": no resident buffer " + name);
    return r->second;
  };

  // two u32 (low, high): Elm's Bytes has no 64-bit integers
  auto u64At = [](const std::byte *p) {
    uint32_t lo, hi;
    std::memcpy(&lo, p, 4);
    std::memcpy(&hi, p + 4, 4);
    return uint64_t(lo) | (uint64_t(hi) << 32);
  };

  // [offset, offset + length) of the file at path, or a failure naming the command
  auto readRange = [&](const std::string &path, uint64_t offset, uint64_t length, const char *command) {
    std::ifstream f{path, std::ios::binary | std::ios::ate};
    if (!f)
      fail(std::string(command) + ": cannot open " + path);
    const uint64_t n = uint64_t(f.tellg());
    if (offset > n || length > n - offset)
      fail(std::string(command) + ": " + path + " has " + std::to_string(n) + " bytes, not [" +
           std::to_string(offset) + ", " + std::to_string(offset + length) + ")");
    std::vector<std::byte> buf(length);
    f.seekg(std::streamoff(offset));
    f.read(reinterpret_cast<char *>(buf.data()), std::streamsize(length));
    return buf;
  };

  // 7: [header] NAME\0 offset(u32 lo, hi) length(u32 lo, hi) PATH
  auto handleLoadRangeInto = [&](std::span<const std::byte> view) {
    auto [name, rest] = nameAndRest(view);
    if (rest.size() < 16)
      fail("loadRangeInto: short message");
    const auto *p = reinterpret_cast<const std::byte *>(rest.data());
    const std::string path(rest.substr(16));
    Resident r;
    r.bytes = readRange(path, u64At(p), u64At(p + 8), "loadRangeInto");
    r.size = r.bytes.size();
    residents.insert_or_assign(name, std::move(r));
  };

  // 8: [header] NAME
  auto handleDrop = [&](std::span<const std::byte> view) {
    std::string name(reinterpret_cast<const char *>(view.data()) + 16, view.size() - 16);
    if (residents.erase(name) == 0)
      fail("drop: no resident buffer " + name);
  };

  // 9: [header id] offset length PATH -> loadIn: [header id] the bytes
  auto handleLoadRange = [&](std::span<const std::byte> view) {
    if (view.size() < 32)
      fail("loadRange: short message");
    const uint32_t id = headerId(view.data());
    const std::string path(reinterpret_cast<const char *>(view.data()) + 32, view.size() - 32);
    auto bytes = readRange(path, u64At(view.data() + 16), u64At(view.data() + 24), "loadRange");
    auto *out = static_cast<uint8_t *>(std::malloc(16 + bytes.size()));
    writeHeader(reinterpret_cast<std::byte *>(out), id);
    if (!bytes.empty())
      std::memcpy(out + 16, bytes.data(), bytes.size());
    eco_port_send_bytes("loadIn", out, 16 + bytes.size(), std::free, out);
  };

  auto handleGet = [&](std::span<const std::byte> view) {
    std::span<const std::byte> v = view;
    const uint32_t id = headerId(v.data());
    std::string name(reinterpret_cast<const char *>(v.data()) + 16, v.size() - 16);
    // `get` of a name never set answers with no bytes (the MNIST runner's end-of-saves marker)
    static const Resident none;
    auto it = residents.find(name);
    const Resident &buf = it == residents.end() ? none : it->second;
    auto *out = static_cast<uint8_t *>(std::malloc(16 + buf.size));
    writeHeader(reinterpret_cast<std::byte *>(out), id);
    if (buf.size)
      std::memcpy(out + 16, buf.data(), buf.size);
    eco_port_send_bytes("getIn", out, 16 + buf.size, std::free, out);
  };

  auto handleSave = [&](std::span<const std::byte> view) {
    auto [name, path] = nameAndRest(view);
    const Resident &buf = findResident(name, "save");
    std::ofstream(std::string(path), std::ios::binary)
        .write(reinterpret_cast<const char *>(buf.data()), std::streamsize(buf.size));
    std::printf("[%7.2fs] HOST saved %s (%zu bytes) to %.*s\n", secs(), name.c_str(), buf.size,
                int(path.size()), path.data());
    std::fflush(stdout);
  };

  auto handleLoadInto = [&](std::span<const std::byte> view) {
    auto [name, path] = nameAndRest(view);
    std::ifstream f{std::string(path), std::ios::binary | std::ios::ate};
    const size_t n = f ? size_t(f.tellg()) : 0;
    Resident r;
    r.bytes.resize(n);
    r.size = n;
    f.seekg(0);
    f.read(reinterpret_cast<char *>(r.bytes.data()), std::streamsize(n));
    residents.insert_or_assign(std::string(name), std::move(r));
  };

  // Every command whose order matters arrives on one port, so the host sees them in the order the
  // program sent them (the runtime orders sends per port, not across ports). The header's second
  // u32 says which command it is.
  std::function<void(std::span<const std::byte>)> dispatch = [&](std::span<const std::byte> v) {
    uint32_t code;
    std::memcpy(&code, v.data() + 4, 4);
    switch (code) {
    case 1: handleRun(v); break;
    case 2: handlePut(v); break;
    case 3: handleGet(v); break;
    case 4: handleSave(v); break;
    case 5: handleLoadInto(v); break;
    case 7: handleLoadRangeInto(v); break;
    case 8: handleDrop(v); break;
    case 9: handleLoadRange(v); break;
    case 6: {
      // a sequence: each command as [u32 length][the command, with its own header], run in order
      size_t off = 16;
      while (off + 4 <= v.size()) {
        uint32_t len;
        std::memcpy(&len, v.data() + off, 4);
        off += 4;
        dispatch(v.subspan(off, len));
        off += len;
      }
      break;
    }
    default:
      std::printf("HOST unknown command %u\n", code);
      std::fflush(stdout);
      std::_Exit(1);
    }
  };
  eco::Subscription sh = hostOut.subscribe([&](const eco::BorrowedBytes &bytes) { dispatch(bytes.view()); });

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
    std::printf("HOST graph %u: %d runs, MAX execute %.1f ms total (%.3f ms each), callback %.1f ms total; "
                "across the Elm boundary per run at most %llu bytes in, %llu bytes out\n",
                id, g.runs, g.execMs, g.runs ? g.execMs / g.runs : 0.0, g.callbackMs,
                (unsigned long long)g.maxIn, (unsigned long long)g.maxOut);
  {
    size_t bytes = 0;
    for (auto &[name, r] : residents)
      bytes += r.size;
    std::printf("HOST residents: %zu buffers, %zu bytes; %llu resident outputs copied (aliased an input)\n",
                residents.size(), bytes, (unsigned long long)aliasedCopies);
  }
  residents.clear(); // before MAX's context goes
  std::printf("[%7.2fs] HOST exit %d\n", secs(), exitCode);
  return exitCode;
}
