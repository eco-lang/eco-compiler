// Spike host: an eco program (TensorService.elm, built as a glibc .so) and libmax in one process.
//
// Elm sends {"batch","x","w","b"} on xOut; the callback (on the eco thread) runs the compiled MAX
// model on those values and sends {"batch","y"} back on yIn; Elm checks y and reports on resultOut.
//
//   tensor_host MODEL.mlir [COLD-MODEL.mlir]   (the second is compiled while Elm runs)
#include <eco/eco_embed.h>

#include "max/c/common.h"
#include "max/c/context.h"
#include "max/c/device.h"
#include "max/c/model.h"
#include "max/c/tensor.h"
#include "max/c/types.h"

#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

namespace {

using Clock = std::chrono::steady_clock;

double msSince(Clock::time_point t0) {
  return std::chrono::duration<double, std::milli>(Clock::now() - t0).count();
}

M_Status *st;
M_RuntimeContext *ctx;
M_Device *host;
M_AsyncModel *model;

std::mutex mutex;
std::condition_variable changed;
bool done = false;

[[noreturn]] void die(const char *what) {
  std::printf("FAIL %s: %s\n", what, M_getError(st));
  std::exit(1);
}

// The numbers in the JSON array under "key". Enough JSON for this fixture.
std::vector<float> floats(const char *json, const char *key) {
  std::vector<float> out;
  std::string pat = std::string("\"") + key + "\":[";
  const char *p = std::strstr(json, pat.c_str());
  if (!p)
    return out;
  p += pat.size();
  while (*p && *p != ']') {
    char *end;
    out.push_back(std::strtof(p, &end));
    p = end;
    if (*p == ',')
      ++p;
  }
  return out;
}

long intField(const char *json, const char *key) {
  std::string pat = std::string("\"") + key + "\":";
  const char *p = std::strstr(json, pat.c_str());
  return p ? std::strtol(p + pat.size(), nullptr, 10) : -1;
}

void onX(const char *json, void *) {
  auto t0 = Clock::now();
  const int64_t batch = intField(json, "batch");
  std::vector<float> x = floats(json, "x"), w = floats(json, "w"), b = floats(json, "b");
  const int64_t k = 4, n = int64_t(b.size());
  const double parseMs = msSince(t0);

  int64_t xs[2] = {batch, k}, wsh[2] = {k, n}, bsh[1] = {n};
  M_TensorSpec *sx = M_newTensorSpec(xs, 2, M_FLOAT32, "x", host);
  M_TensorSpec *sw = M_newTensorSpec(wsh, 2, M_FLOAT32, "w", host);
  M_TensorSpec *sb = M_newTensorSpec(bsh, 1, M_FLOAT32, "b", host);
  M_AsyncTensorMap *in = M_newAsyncTensorMap(ctx);
  M_borrowTensorInto(in, x.data(), sx, st);
  M_borrowTensorInto(in, w.data(), sw, st);
  M_borrowTensorInto(in, b.data(), sb, st);
  if (M_isError(st))
    die("borrow");
  auto t1 = Clock::now();
  M_AsyncTensorMap *outs = M_executeModelSync(ctx, model, in, st);
  if (M_isError(st))
    die("execute");
  const double execMs = msSince(t1);
  M_AsyncTensor *y = M_getTensorByNameFrom(outs, "y", st);
  if (M_isError(st))
    die("get y");
  const float *yd = static_cast<const float *>(M_getTensorData(y));
  const size_t yn = M_getTensorNumElements(y);

  auto t2 = Clock::now();
  std::string reply = "{\"batch\":" + std::to_string(batch) + ",\"y\":[";
  char buf[32];
  for (size_t i = 0; i < yn; ++i) {
    std::snprintf(buf, sizeof buf, i ? ",%.9g" : "%.9g", double(yd[i]));
    reply += buf;
  }
  reply += "]}";
  const double encodeMs = msSince(t2);
  std::printf("HOST batch=%lld json-in=%zu B parse=%.3f ms exec=%.3f ms encode=%.3f ms\n",
              (long long)batch, std::strlen(json), parseMs, execMs, encodeMs);
  std::fflush(stdout);

  M_freeTensor(y);
  M_freeAsyncTensorMap(outs);
  M_freeAsyncTensorMap(in);
  M_freeTensorSpec(sx);
  M_freeTensorSpec(sw);
  M_freeTensorSpec(sb);
  if (eco_port_send("yIn", reply.c_str()) != 0)
    std::printf("HOST send yIn failed\n");
}

void onResult(const char *json, void *) {
  std::printf("%s\n", json);
  std::fflush(stdout);
  if (std::strcmp(json, "\"done\"") == 0) {
    std::lock_guard<std::mutex> lock(mutex);
    done = true;
    changed.notify_all();
  }
}

} // namespace

int main(int argc, char **argv) {
  if (argc < 2) {
    std::fprintf(stderr, "usage: tensor_host MODEL.mlir\n");
    return 2;
  }
  auto t0 = Clock::now();
  st = M_newStatus();
  M_RuntimeConfig *rc = M_newRuntimeConfig();
  host = M_newDevice(M_HOST, 0, st);
  M_runtimeConfigAddDevice(rc, host);
  ctx = M_newRuntimeContext(rc, st);
  if (M_isError(st))
    die("context");
  M_CompileConfig *cc = M_newCompileConfig();
  M_setModelPath(cc, argv[1]);
  M_AsyncCompiledModel *cm = M_compileModelSync(ctx, &cc, st);
  if (M_isError(st))
    die("compile");
  model = M_initModel(ctx, cm, nullptr, st);
  M_waitForModel(model, st);
  if (M_isError(st))
    die("init");
  std::printf("HOST MAX %s ready in %.0f ms\n", M_version(), msSince(t0));

  eco_port_subscribe("xOut", onX, nullptr);
  eco_port_subscribe("resultOut", onResult, nullptr);
  // Elm's argv[0] only; the model path is the host's.
  if (int rc2 = eco_app_start(1, argv, nullptr); rc2 != 0) {
    std::printf("HOST eco start failed: %d\n", rc2);
    return 1;
  }
  if (argc > 2) {
    // A cold compile on this thread while the eco thread runs.
    auto t1 = Clock::now();
    M_Status *st2 = M_newStatus();
    M_CompileConfig *cc2 = M_newCompileConfig();
    M_setModelPath(cc2, argv[2]);
    M_AsyncCompiledModel *cm2 = M_compileModelSync(ctx, &cc2, st2);
    std::printf("HOST concurrent compile %s in %.0f ms\n", M_isError(st2) ? M_getError(st2) : "ok",
                msSince(t1));
    std::fflush(stdout);
    if (cm2)
      M_freeCompiledModel(cm2);
    M_freeStatus(st2);
  }
  {
    std::unique_lock<std::mutex> lock(mutex);
    changed.wait(lock, [] { return done; });
  }
  eco_app_stop();
  const int code = eco_app_join();
  M_freeModel(model);
  M_freeCompiledModel(cm);
  M_freeRuntimeContext(ctx);
  M_freeDevice(host);
  M_freeRuntimeConfig(rc);
  M_freeStatus(st);
  std::printf("HOST exit: %d\n", code);
  return code;
}
