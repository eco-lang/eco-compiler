// A generic MAX host for an eco program: it compiles the graphs the program sends, keeps its resident
// buffers and runs the graphs on them, and knows nothing about the models. It speaks version 2 of the
// wire protocol of the package's `Max.Session` (src/Max/Internal/Protocol.elm).
//
// Ports, bound by name:
//   maxOut (Bytes, out of Elm)   every request, handled in the order the program sent them
//   maxIn  (Bytes, into Elm)     every reply
//   logOut (String, optional)    printed with the time since start; a program need not declare it
//
// Every message starts with a 16-byte header of four little-endian u32: id, code, status, 0. A reply
// carries its request's id and code, and status 0 for success or 1 for failure, with a UTF-8 message
// as its payload. A reply is at most 2^32 - 1 bytes, header included; a run or get that would need
// more stops the host. Tensors are each padded to 16 bytes; a file range's offset and length are each
// two u32, low then high.
//
//   code  request        payload after the header                 reply
//    1    run            the fed inputs in graph order, padded    the fed outputs in graph order, padded
//    2    put            NAME\0 bytes                             none
//    3    get            NAME                                     the buffer's bytes (none if never set)
//    4    save           NAME\0 PATH                              none
//    5    loadInto       NAME\0 PATH                              none
//    6    sequence       each command as [u32 length][command]    each command's own reply, in order
//    7    loadRangeInto  NAME\0 offset length PATH                none
//    8    drop           NAME                                     none
//    9    loadRange      offset length PATH                       the bytes; status 1 if out of range
//   10    compile        spec lines, then MLIR                    no payload; status 1 with MAX's error
//   11    load           PATH                                     the whole file; status 1 if unreadable
//   12    finish         u32 exit code                            none: the program is stopped, the host
//                                                                 exits with that code (its low 8 bits),
//                                                                 and every later request is ignored
//
// The id of a run or a compile is the graph's. A compile's payload is two spec lines then the MLIR, as
// text or bytecode (told apart by bytecode's magic, "ML\xEFR"):
//   in name:dtype:AxB[:r=RES] ...\nout name:dtype:AxB[:r=RES] ...\n
// `r=RES` marks a resident tensor: an input read from the host buffer RES, an output that replaces RES
// after the run (parameters, optimizer state); only fed tensors travel with a run and its reply. The
// MLIR is written to WORKDIR/graph-<id>.mlir[bc] and compiled on a worker thread, so the program goes
// on meanwhile; a run of a graph whose compile is in flight waits for it, and a run of a graph whose
// compile failed is a host failure.
//
// A run executes on the eco thread with its fed inputs borrowed in place from the Elm heap, and its fed
// outputs copied once, straight into the reply's Bytes. Resident outputs stay where MAX put them (no
// copy), unless MAX placed one inside an input buffer: that one is copied.
//
// Only compile, load and loadRange reply with failures. Any other failure (a missing resident, bad run
// inputs, a malformed request) is printed as a HOST line and ends the process with exit code 1.
//
//   max_host WORKDIR FLAGS-JSON
//
// ECO_MAX_THREADS=N sizes MAX's CPU worker pool; ECO_MAX_BUSY_WAIT_US=T is how long an idle worker
// spins before it sleeps (MAX's default: 200 µs, on every core). The host prints each graph's run
// statistics and the resident buffers when the program finishes.
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
#include <fstream>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <span>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {

using Clock = std::chrono::steady_clock;
const Clock::time_point start = Clock::now();

double secs() { return std::chrono::duration<double>(Clock::now() - start).count(); }

double msSince(Clock::time_point t0) {
  return std::chrono::duration<double, std::milli>(Clock::now() - t0).count();
}

// The request codes (the header's second u32), which their replies carry back.
enum Code : uint32_t {
  Run = 1,
  Put = 2,
  Get = 3,
  Save = 4,
  LoadInto = 5,
  Sequence = 6,
  LoadRangeInto = 7,
  Drop = 8,
  LoadRange = 9,
  Compile = 10,
  Load = 11,
  Finish = 12,
};

enum Status : uint32_t { Ok = 0, Failed = 1 };

[[noreturn]] void fatal(const std::string &what) {
  std::printf("HOST %s\n", what.c_str());
  std::fflush(stdout);
  std::_Exit(1);
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

// A graph id's compiled model. Its compiles are numbered: `requested` counts those the program asked
// for, `settled` is the latest whose result is in; one is in flight while settled < requested.
struct Graph {
  uint32_t requested = 0, settled = 0;
  bool failed = false; // the settled compile failed; `error` says why
  std::string error;
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
// Graphs by id. The eco thread adds entries and runs them; compile workers settle them.
std::mutex graphsMutex;
std::condition_variable graphSettled;
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
// Compile workers (started on the eco thread, joined by main once the program has stopped).
std::vector<std::thread> compilers;

// maxIn, for the compile workers' replies.
eco_port *maxInPort = nullptr;

std::mutex doneMutex;
std::condition_variable doneChanged;
bool finished = false;
int exitCode = 0;

size_t padded(size_t n) { return (n + 15) / 16 * 16; }

// The most bytes one reply can be, header included: the runtime's emit takes no more.
constexpr uint64_t kMaxReply = UINT32_MAX;

uint32_t u32At(const std::byte *p) {
  uint32_t x;
  std::memcpy(&x, p, 4);
  return x;
}

// two u32 (low, high): Elm's Bytes has no 64-bit integers
uint64_t u64At(const std::byte *p) { return uint64_t(u32At(p)) | (uint64_t(u32At(p + 4)) << 32); }

void writeHeader(std::byte *p, uint32_t id, uint32_t code, uint32_t status) {
  const uint32_t h[4] = {id, code, status, 0};
  std::memcpy(p, h, 16);
}

// A reply the runtime did not take (`rc`: an ECO_EMIT_* result). Fatal unless the program has stopped
// (after finish), when replies are dropped.
void replyRefused(int rc, uint32_t id, uint32_t code) {
  if (eco_port_kind(maxInPort) != ECO_PORT_IN_BYTES)
    fatal("cannot reply to request " + std::to_string(id) + " (code " + std::to_string(code) +
          "): the program declares no `port maxIn : (Bytes -> msg) -> Sub msg`");
  if (rc != ECO_EMIT_NOT_A_PORT)
    fatal("reply to request " + std::to_string(id) + " (code " + std::to_string(code) +
          ") not sent: emit result " + std::to_string(rc));
}

// A reply from a thread other than the eco thread: lent to the runtime, freed after delivery.
void sendReply(uint32_t id, uint32_t code, uint32_t status, const std::string &payload) {
  const size_t n = 16 + payload.size();
  auto *buf = static_cast<std::byte *>(std::malloc(n));
  writeHeader(buf, id, code, status);
  std::memcpy(buf + 16, payload.data(), payload.size());
  if (eco_port_send_buffer(maxInPort, reinterpret_cast<const uint8_t *>(buf), n, std::free, buf) != 0) {
    std::free(buf); // not queued, so not released
    replyRefused(ECO_EMIT_NOT_A_PORT, id, code);
  }
}

// "in x:ui8:100x784 y:ui8:100 w:f32:784x128:r=param0" -> specs (a scalar has no dims: "s:f32:"),
// appended to `out`; or why the line cannot be read, which fails the compile. A name holding
// whitespace or a colon makes a word this refuses, since names are written unescaped.
std::string parseSpecs(const std::string &line, std::vector<Spec> &out) {
  static const std::map<std::string, std::pair<M_Dtype, size_t>> dtypes = {
      {"f16", {M_FLOAT16, 2}}, {"bf16", {M_BFLOAT16, 2}}, {"f32", {M_FLOAT32, 4}},
      {"f64", {M_FLOAT64, 8}}, {"si8", {M_INT8, 1}},      {"si32", {M_INT32, 4}},
      {"si64", {M_INT64, 8}},  {"ui8", {M_UINT8, 1}},     {"ui64", {M_UINT64, 8}},
      {"bool", {M_BOOL, 1}}};
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
    const std::string bad = "bad spec word `" + word + "`: ";
    if (parts.size() > 4 || (parts.size() == 4 && parts[3].rfind("r=", 0) != 0))
      return bad + "a name holds a colon, or a field is not `r=RESIDENT`";
    Spec s;
    s.name = parts[0];
    auto dt = dtypes.find(parts[1]);
    if (dt == dtypes.end())
      return bad + "unknown dtype `" + parts[1] + "` (a name holding whitespace or a colon?)";
    s.dtype = dt->second.first;
    s.elemSize = dt->second.second;
    std::istringstream dims(parts[2]);
    std::string d;
    while (std::getline(dims, d, 'x')) {
      if (d.empty())
        continue;
      if (d.find_first_not_of("0123456789") != std::string::npos)
        return bad + "dimension `" + d + "` is not a number";
      s.shape.push_back(std::atoll(d.c_str()));
    }
    if (parts.size() == 4)
      s.resident = parts[3].substr(2);
    out.push_back(s);
  }
  return "";
}

// Compile number `n` of graph `id` (a worker thread). The reply is queued before the result is
// settled, so a run waiting for this compile replies after it.
void compileGraph(uint32_t id, uint32_t n, std::string text) {
  // Spec lines that cannot be read and a graph file that cannot be written fail the compile, as
  // MAX's own errors do: every compile is answered, and none ends the program.
  std::vector<Spec> inputs, outputs;
  std::string error;
  const size_t l1 = text.find('\n'), l2 = l1 == std::string::npos ? l1 : text.find('\n', l1 + 1);
  if (l2 == std::string::npos)
    error = "no `in` and `out` spec lines";
  else if (error = parseSpecs(text.substr(0, l1), inputs); error.empty())
    error = parseSpecs(text.substr(l1 + 1, l2 - l1 - 1), outputs);
  // MAX reads text or bytecode from the file alike; the extension only says which it is.
  const std::string mlir = l2 == std::string::npos ? std::string() : text.substr(l2 + 1);
  const bool bytecode = mlir.compare(0, 4, "ML\xEFR") == 0;
  const std::string path =
      workDir + "/graph-" + std::to_string(id) + (bytecode ? ".mlirbc" : ".mlir");
  if (error.empty()) {
    std::ofstream file(path, std::ios::binary);
    file.write(mlir.data(), std::streamsize(mlir.size()));
    file.close(); // sets failbit if the last bytes cannot be flushed
    if (!file)
      error = "cannot write " + path;
  }

  auto t0 = Clock::now();
  M_Status *st = M_newStatus();
  M_AsyncCompiledModel *compiled = nullptr;
  M_AsyncModel *model = nullptr;
  if (error.empty()) {
    M_CompileConfig *cc = M_newCompileConfig();
    M_setModelPath(cc, path.c_str());
    compiled = M_compileModelSync(ctx, &cc, st);
    if (!M_isError(st)) {
      model = M_initModel(ctx, compiled, nullptr, st);
      if (!M_isError(st))
        M_waitForModel(model, st);
    }
    if (M_isError(st)) {
      const char *why = M_getError(st);
      error = why && *why ? why : "MAX gave no error text";
    }
  }
  const bool ok = error.empty();
  const double ms = msSince(t0);
  std::vector<M_TensorSpec *> inputSpecs;
  if (ok) {
    std::printf("[%7.2fs] HOST compiled graph %u (%s, %zu bytes of %s) in %.1f s\n", secs(), id,
                path.c_str(), mlir.size(), bytecode ? "MLIR bytecode" : "mo text", ms / 1000);
    for (const Spec &s : inputs)
      inputSpecs.push_back(M_newTensorSpec(s.shape.data(), int64_t(s.shape.size()), s.dtype,
                                           s.name.c_str(), host));
  } else {
    std::printf("[%7.2fs] HOST compile of graph %u failed: %s\n", secs(), id, error.c_str());
  }
  std::fflush(stdout);
  M_freeStatus(st);

  sendReply(id, Compile, ok ? Ok : Failed, error);
  {
    std::lock_guard<std::mutex> lock(graphsMutex);
    Graph &g = graphs[id];
    if (n > g.settled) { // a later compile of this id that settled first wins
      g.settled = n;
      g.failed = !ok;
      g.error = error;
      if (ok) {
        g.compiled = compiled;
        g.model = model;
        g.inputs = std::move(inputs);
        g.outputs = std::move(outputs);
        g.inputSpecs = std::move(inputSpecs);
      }
    }
  }
  graphSettled.notify_all();
}

// Graph `id`, once no compile of it is in flight (eco thread).
Graph &compiledGraph(uint32_t id) {
  std::unique_lock<std::mutex> lock(graphsMutex);
  auto it = graphs.find(id);
  if (it == graphs.end())
    fatal("run of graph " + std::to_string(id) + ", which was never compiled");
  Graph &g = it->second;
  graphSettled.wait(lock, [&] { return g.settled == g.requested; });
  if (g.failed)
    fatal("run of graph " + std::to_string(id) + ", whose compile failed: " + g.error);
  return g;
}

// Opens `path` for its bytes [offset, offset + length), or the whole file when `whole` (which sets
// offset and length); returns why it cannot, or "" when it can.
std::string openRange(std::ifstream &f, const std::string &path, bool whole, uint64_t &offset,
                      uint64_t &length) {
  f.open(path, std::ios::binary | std::ios::ate);
  if (!f)
    return "cannot open " + path;
  const uint64_t n = uint64_t(f.tellg());
  if (whole) {
    offset = 0;
    length = n;
  } else if (offset > n || length > n - offset) {
    return path + " has " + std::to_string(n) + " bytes, not [" + std::to_string(offset) + ", " +
           std::to_string(offset + length) + ")";
  }
  f.seekg(std::streamoff(offset));
  return "";
}

// "NAME\0rest" after the 16-byte header
std::pair<std::string, std::string_view> nameAndRest(std::span<const std::byte> v) {
  const char *p = reinterpret_cast<const char *>(v.data()) + 16;
  const size_t n = v.size() - 16;
  const size_t z = std::find(p, p + n, '\0') - p;
  const size_t after = std::min(z + 1, n);
  return {std::string(p, z), std::string_view(p + after, n - after)};
}

// Everything after the 16-byte header, as text
std::string afterHeader(std::span<const std::byte> v) {
  return std::string(reinterpret_cast<const char *>(v.data()) + 16, v.size() - 16);
}

} // namespace

int main(int argc, char **argv) {
  if (argc < 3) {
    std::fprintf(stderr, "usage: max_host WORKDIR FLAGS-JSON\n");
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

  // Resolved before the program starts, so before it registers any port: a name it never declares
  // is accepted here and simply never used.
  const eco::BytesOutPort maxOut("maxOut");
  const eco::BytesInPort maxIn("maxIn");
  maxInPort = maxIn.handle();

  // Replies on the eco thread: emitted, so they are written straight into the Elm heap.
  auto reply = [&](uint32_t id, uint32_t code, uint32_t status, std::span<const std::byte> payload) {
    const size_t total = 16 + payload.size();
    if (total > kMaxReply) // a get of a buffer this large, the only reply that can be
      fatal("reply to request " + std::to_string(id) + " (code " + std::to_string(code) + ") of " +
            std::to_string(total) + " bytes is too large for one reply");
    const eco::EmitResult r = maxIn.emit(total, [&](std::span<std::byte> dst) {
      writeHeader(dst.data(), id, code, status);
      if (!payload.empty())
        std::memcpy(dst.data() + 16, payload.data(), payload.size());
      return total;
    });
    if (r != eco::EmitResult::Queued)
      replyRefused(int(r), id, code);
  };
  auto replyFailure = [&](uint32_t id, uint32_t code, const std::string &message) {
    reply(id, code, Failed, std::as_bytes(std::span(message.data(), message.size())));
  };

  // 10: [id, 10] spec lines, MLIR -> compiled on a worker; the reply comes from there.
  auto handleCompile = [&](std::span<const std::byte> v) {
    const uint32_t id = u32At(v.data());
    uint32_t n;
    {
      std::lock_guard<std::mutex> lock(graphsMutex);
      n = ++graphs[id].requested;
    }
    // The text is copied out: the borrowed bytes are only valid during this call.
    compilers.emplace_back(compileGraph, id, n, afterHeader(v));
  };

  M_Status *rst = M_newStatus();
  // 1: [id, 1] the fed inputs -> [id, 1, 0] the fed outputs
  auto handleRun = [&](std::span<const std::byte> v) {
    const uint32_t id = u32At(v.data());
    Graph *g = &compiledGraph(id);
    size_t replySize = 16;
    for (const Spec &s : g->outputs)
      if (s.resident.empty())
        replySize += padded(s.bytes());
    if (replySize > kMaxReply) // refused before the run, so no resident buffer is replaced
      fatal("run " + std::to_string(id) + ": its fed outputs (" + std::to_string(replySize) +
            " bytes with the header) are too large for one reply");
    auto t0 = Clock::now(); // after any wait for the compile
    // Borrow every fed input in place (no copy out of the Elm heap, and no GC until we return) and
    // every resident input from its host buffer.
    M_AsyncTensorMap *in = M_newAsyncTensorMap(ctx);
    std::vector<std::pair<const std::byte *, size_t>> inputRanges;
    size_t off = 16;
    for (size_t i = 0; i < g->inputs.size(); ++i) {
      const Spec &s = g->inputs[i];
      if (!s.resident.empty()) {
        auto r = residents.find(s.resident);
        if (r == residents.end() || r->second.size != s.bytes())
          fatal("run " + std::to_string(id) + ": resident " + s.resident + " is " +
                (r == residents.end() ? "missing" : "the wrong size") + " (" +
                std::to_string(s.bytes()) + " bytes wanted)");
        M_borrowTensorInto(in, const_cast<std::byte *>(r->second.data()), g->inputSpecs[i], rst);
        inputRanges.emplace_back(r->second.data(), s.bytes());
      } else {
        if (off + s.bytes() > v.size())
          fatal("run " + std::to_string(id) + ": bad inputs (" + std::to_string(v.size()) +
                " bytes, input " + s.name + " not in them)");
        M_borrowTensorInto(in, const_cast<std::byte *>(v.data() + off), g->inputSpecs[i], rst);
        inputRanges.emplace_back(v.data() + off, s.bytes());
        off += padded(s.bytes());
      }
    }
    if (M_isError(rst) || off != v.size())
      fatal("run " + std::to_string(id) + ": bad inputs (" + std::to_string(off) + " of " +
            std::to_string(v.size()) + " bytes)" +
            (M_isError(rst) ? std::string(": ") + M_getError(rst) : std::string()));
    auto t1 = Clock::now();
    M_AsyncTensorMap *outs = M_executeModelSync(ctx, g->model, in, rst);
    if (M_isError(rst))
      fatal("run " + std::to_string(id) + ": " + M_getError(rst));
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
    const eco::EmitResult sent = maxIn.emit(total, [&](std::span<std::byte> dst) {
      std::memset(dst.data(), 0, total);
      writeHeader(dst.data(), id, Run, Ok);
      size_t o = 16;
      for (size_t i = 0; i < results.size(); ++i) {
        if (!g->outputs[i].resident.empty())
          continue;
        std::memcpy(dst.data() + o, M_getTensorData(results[i]), g->outputs[i].bytes());
        o += padded(g->outputs[i].bytes());
      }
      return total;
    });
    if (sent != eco::EmitResult::Queued)
      replyRefused(int(sent), id, Run);
    for (M_AsyncTensor *t : results)
      M_freeTensor(t);
    owner.reset(); // freed here unless a resident output keeps it
    M_freeAsyncTensorMap(in);
    for (auto &[name, r] : replaced)
      residents.insert_or_assign(name, std::move(r));
    g->runs++;
    g->bytesIn += v.size();
    g->bytesOut += total;
    g->maxIn = std::max<uint64_t>(g->maxIn, v.size());
    g->maxOut = std::max<uint64_t>(g->maxOut, total);
    g->callbackMs += msSince(t0);
  };

  auto findResident = [&](const std::string &name, const char *command) -> const Resident & {
    auto r = residents.find(name);
    if (r == residents.end())
      fatal(std::string(command) + ": no resident buffer " + name);
    return r->second;
  };

  // 2: NAME\0 bytes
  auto handlePut = [&](std::span<const std::byte> v) {
    auto [name, rest] = nameAndRest(v);
    residents.insert_or_assign(name, Resident::ofBytes(rest.data(), rest.size()));
  };

  // 3: [id, 3] NAME -> [id, 3, 0] the buffer's bytes; a name never set answers with no bytes
  auto handleGet = [&](std::span<const std::byte> v) {
    const uint32_t id = u32At(v.data());
    auto it = residents.find(afterHeader(v));
    if (it == residents.end())
      reply(id, Get, Ok, {});
    else
      reply(id, Get, Ok, std::span(it->second.data(), it->second.size));
  };

  // 4: NAME\0 PATH
  auto handleSave = [&](std::span<const std::byte> v) {
    auto [name, path] = nameAndRest(v);
    const Resident &buf = findResident(name, "save");
    std::ofstream f(std::string(path), std::ios::binary);
    f.write(reinterpret_cast<const char *>(buf.data()), std::streamsize(buf.size));
    f.close(); // sets failbit if the last bytes cannot be flushed
    if (!f)
      fatal("save: cannot write " + name + " to " + std::string(path));
    std::printf("[%7.2fs] HOST saved %s (%zu bytes) to %.*s\n", secs(), name.c_str(), buf.size,
                int(path.size()), path.data());
    std::fflush(stdout);
  };

  // 5: NAME\0 PATH (a file that cannot be opened or read stops the host)
  auto handleLoadInto = [&](std::span<const std::byte> v) {
    auto [name, path] = nameAndRest(v);
    std::ifstream f{std::string(path), std::ios::binary | std::ios::ate};
    if (!f)
      fatal("loadInto: cannot open " + std::string(path));
    const std::streamoff end = f.tellg(); // -1 for a file that cannot be sized, such as a pipe
    if (end < 0)
      fatal("loadInto: cannot read the size of " + std::string(path));
    const size_t n = size_t(end);
    Resident r;
    r.bytes.resize(n);
    r.size = n;
    f.seekg(0);
    if (!f.read(reinterpret_cast<char *>(r.bytes.data()), std::streamsize(n)))
      fatal("loadInto: cannot read " + std::string(path));
    residents.insert_or_assign(std::string(name), std::move(r));
  };

  // 7: NAME\0 offset length PATH -> bytes [offset, offset + length) of PATH into the buffer NAME
  auto handleLoadRangeInto = [&](std::span<const std::byte> v) {
    auto [name, rest] = nameAndRest(v);
    if (rest.size() < 16)
      fatal("loadRangeInto: short message");
    const auto *p = reinterpret_cast<const std::byte *>(rest.data());
    const std::string path(rest.substr(16));
    uint64_t offset = u64At(p), length = u64At(p + 8);
    std::ifstream f;
    if (std::string why = openRange(f, path, false, offset, length); !why.empty())
      fatal("loadRangeInto: " + why);
    Resident r;
    r.bytes.resize(length);
    r.size = length;
    if (!f.read(reinterpret_cast<char *>(r.bytes.data()), std::streamsize(length)))
      fatal("loadRangeInto: cannot read " + path);
    residents.insert_or_assign(name, std::move(r));
  };

  // 8: NAME
  auto handleDrop = [&](std::span<const std::byte> v) {
    const std::string name = afterHeader(v);
    if (residents.erase(name) == 0)
      fatal("drop: no resident buffer " + name);
  };

  // 9 and 11: [id, code] -> [id, code, 0] the bytes [offset, offset + length) of the file at path
  // (the whole file when `whole`), read straight into the Elm heap; or [id, code, 1] why not.
  auto replyFile = [&](uint32_t id, uint32_t code, const std::string &path, bool whole, uint64_t offset,
                       uint64_t length) {
    const std::string command = code == Load ? "load: " : "loadRange: ";
    std::ifstream f;
    if (std::string why = openRange(f, path, whole, offset, length); !why.empty())
      return replyFailure(id, code, command + why);
    if (length > kMaxReply - 16)
      return replyFailure(id, code, command + std::to_string(length) + " bytes of " + path +
                                        " are too many for one reply");
    const size_t total = 16 + length;
    const eco::EmitResult r =
        maxIn.emit(total, [&](std::span<std::byte> dst) -> std::optional<size_t> {
          writeHeader(dst.data(), id, code, Ok);
          if (!f.read(reinterpret_cast<char *>(dst.data() + 16), std::streamsize(length)))
            return std::nullopt;
          return total;
        });
    if (r == eco::EmitResult::Cancelled)
      return replyFailure(id, code, command + "cannot read " + path);
    if (r != eco::EmitResult::Queued)
      return replyRefused(int(r), id, code);
    if (code == Load) {
      std::printf("[%7.2fs] HOST loaded %s (%llu bytes)\n", secs(), path.c_str(),
                  (unsigned long long)length);
      std::fflush(stdout);
    }
  };

  // 9: [id, 9] offset length PATH
  auto handleLoadRange = [&](std::span<const std::byte> v) {
    if (v.size() < 32)
      fatal("loadRange: short message");
    const std::string path(reinterpret_cast<const char *>(v.data()) + 32, v.size() - 32);
    replyFile(u32At(v.data()), LoadRange, path, false, u64At(v.data() + 16), u64At(v.data() + 24));
  };

  // 11: [id, 11] PATH
  auto handleLoad = [&](std::span<const std::byte> v) {
    replyFile(u32At(v.data()), Load, afterHeader(v), true, 0, 0);
  };

  // Set by finish (the eco thread): every request after it, later in the same sequence or in a later
  // message, is ignored, as the in-Elm backend ignores them.
  bool stopping = false;

  // 12: u32 exit code -> main stops the program and exits with it
  auto handleFinish = [&](std::span<const std::byte> v) {
    if (v.size() < 20)
      fatal("finish: short message");
    std::lock_guard<std::mutex> lock(doneMutex);
    exitCode = int(u32At(v.data() + 16));
    finished = true;
    stopping = true; // dispatch handles nothing more
    doneChanged.notify_all();
  };

  // Every request arrives on maxOut, so the host sees them in the order the program sent them (the
  // runtime orders sends per port, not across ports). The header's second u32 says which it is.
  std::function<void(std::span<const std::byte>)> dispatch = [&](std::span<const std::byte> v) {
    if (stopping)
      return;
    if (v.size() < 16)
      fatal("request of " + std::to_string(v.size()) + " bytes, shorter than its header");
    const uint32_t code = u32At(v.data() + 4);
    switch (code) {
    case Run: handleRun(v); break;
    case Put: handlePut(v); break;
    case Get: handleGet(v); break;
    case Save: handleSave(v); break;
    case LoadInto: handleLoadInto(v); break;
    case Sequence: {
      // each command as [u32 length][the command, with its own header], run in order
      size_t off = 16;
      while (off < v.size() && !stopping) {
        if (v.size() - off < 4 || v.size() - off - 4 < u32At(v.data() + off))
          fatal("sequence: a command overruns the message");
        const uint32_t len = u32At(v.data() + off);
        dispatch(v.subspan(off + 4, len));
        off += 4 + len;
      }
      break;
    }
    case LoadRangeInto: handleLoadRangeInto(v); break;
    case Drop: handleDrop(v); break;
    case LoadRange: handleLoadRange(v); break;
    case Compile: handleCompile(v); break;
    case Load: handleLoad(v); break;
    case Finish: handleFinish(v); break;
    default: fatal("unknown request code " + std::to_string(code));
    }
  };
  eco::Subscription requests =
      maxOut.subscribe([&](const eco::BorrowedBytes &bytes) { dispatch(bytes.view()); });

  // logOut is optional. A program that does not declare it never registers it: the subscription
  // waits on a name the runtime knows only from here, and is never called. (Resolving and
  // subscribing throw only for a port already registered as another kind, which none is before the
  // program starts; a program whose logOut is not a String port just goes unlogged.)
  eco::Subscription logs;
  try {
    logs = eco::JsonOutPort("logOut").subscribe([](std::string_view json) {
      std::printf("[%7.2fs] %.*s\n", secs(), int(json.size()), json.data());
      std::fflush(stdout);
    });
  } catch (const std::invalid_argument &) {
  }

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
    if (g.model)
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
