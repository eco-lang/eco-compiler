// Spike host, zero-copy version: TensorBytes.elm (built as a .so from the current tree) and libmax
// in one process. Elm sends [w | b | x] as one Bytes on xOut; inside the callback, on the eco
// thread and with GC paused, the three tensors are borrowed straight out of the Elm heap, the
// model runs, and y is emitted back into the heap on yIn.
//
//   bytes_host MODEL.mlir [quiet|verbose] [COLD-MODEL.mlir]   (quiet prints only failures)
#include <eco/eco_embed.hpp>

#include "max/c/common.h"
#include "max/c/context.h"
#include "max/c/device.h"
#include "max/c/model.h"
#include "max/c/tensor.h"
#include "max/c/types.h"

#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>

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
bool verbose = true;

[[noreturn]] void die(const char *what) {
  std::printf("FAIL %s: %s\n", what, M_getError(st));
  std::exit(1);
}

} // namespace

int main(int argc, char **argv) {
  if (argc < 2) {
    std::fprintf(stderr, "usage: bytes_host MODEL.mlir [quiet|verbose] [COLD-MODEL.mlir]\n");
    return 2;
  }
  verbose = !(argc > 2 && std::strcmp(argv[2], "quiet") == 0);
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

  const eco::BytesOutPort xOut("xOut");
  const eco::BytesInPort yIn("yIn");
  const eco::JsonOutPort resultOut("resultOut");

  eco::Subscription xs = xOut.subscribe([&yIn](const eco::BorrowedBytes &bytes) {
    auto t1 = Clock::now();
    const std::span<const std::byte> view = bytes.view();
    const int64_t k = 4, n = 3;
    const int64_t floats = int64_t(view.size() / 4);
    const int64_t batch = (floats - k * n - n) / k;
    // Borrowed in place: no copy out of the Elm heap. Safe because no GC runs until we return.
    auto *base = const_cast<float *>(reinterpret_cast<const float *>(view.data()));
    float *w = base, *b = base + k * n, *x = base + k * n + n;
    int64_t xsh[2] = {batch, k}, wsh[2] = {k, n}, bsh[1] = {n};
    M_TensorSpec *sx = M_newTensorSpec(xsh, 2, M_FLOAT32, "x", host);
    M_TensorSpec *sw = M_newTensorSpec(wsh, 2, M_FLOAT32, "w", host);
    M_TensorSpec *sb = M_newTensorSpec(bsh, 1, M_FLOAT32, "b", host);
    M_AsyncTensorMap *in = M_newAsyncTensorMap(ctx);
    M_borrowTensorInto(in, x, sx, st);
    M_borrowTensorInto(in, w, sw, st);
    M_borrowTensorInto(in, b, sb, st);
    if (M_isError(st))
      die("borrow");
    auto t2 = Clock::now();
    M_AsyncTensorMap *outs = M_executeModelSync(ctx, model, in, st);
    if (M_isError(st))
      die("execute");
    const double execMs = msSince(t2);
    M_AsyncTensor *y = M_getTensorByNameFrom(outs, "y", st);
    if (M_isError(st))
      die("get y");
    const void *yd = M_getTensorData(y);
    const size_t ybytes = M_getTensorNumElements(y) * 4;
    // One copy: MAX's output buffer straight into a new Elm Bytes.
    const eco::EmitResult er = yIn.emit(ybytes, [yd, ybytes](std::span<std::byte> dst) {
      std::memcpy(dst.data(), yd, ybytes);
      return ybytes;
    });
    if (er != eco::EmitResult::Queued)
      std::printf("HOST emit failed: %d\n", static_cast<int>(er));
    if (verbose)
      std::printf("HOST batch=%lld bytes-in=%zu x%%64=%lu exec=%.3f ms callback=%.3f ms\n",
                  (long long)batch, view.size(), (unsigned long)(uintptr_t(x) % 64), execMs,
                  msSince(t1));
    std::fflush(stdout);
    M_freeTensor(y);
    M_freeAsyncTensorMap(outs);
    M_freeAsyncTensorMap(in);
    M_freeTensorSpec(sx);
    M_freeTensorSpec(sw);
    M_freeTensorSpec(sb);
  });

  eco::Subscription rs = resultOut.subscribe([](std::string_view json) {
    if (json == "\"done\"") {
      std::lock_guard<std::mutex> lock(mutex);
      done = true;
      changed.notify_all();
    } else if (verbose || json.find("OK") == std::string_view::npos) {
      std::printf("%.*s\n", int(json.size()), json.data());
      std::fflush(stdout);
    }
  });

  auto t3 = Clock::now();
  if (int rc2 = eco_app_start(1, argv, nullptr); rc2 != 0) {
    std::printf("HOST eco start failed: %d\n", rc2);
    return 1;
  }
  if (argc > 3) {
    auto t4 = Clock::now();
    M_Status *st2 = M_newStatus();
    M_CompileConfig *cc2 = M_newCompileConfig();
    M_setModelPath(cc2, argv[3]);
    M_AsyncCompiledModel *cm2 = M_compileModelSync(ctx, &cc2, st2);
    std::printf("HOST concurrent compile %s in %.0f ms\n", M_isError(st2) ? M_getError(st2) : "ok",
                msSince(t4));
    if (cm2)
      M_freeCompiledModel(cm2);
    M_freeStatus(st2);
  }
  {
    std::unique_lock<std::mutex> lock(mutex);
    changed.wait(lock, [] { return done; });
  }
  std::printf("HOST Elm run took %.0f ms\n", msSince(t3));
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
