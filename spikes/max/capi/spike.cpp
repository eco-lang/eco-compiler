// Spike: drive libmax's C API with hand-written mo MLIR.
//
//   spike MODEL.mlir [--f64] [--bias2d] [--compile-twice] [--expect-fail]
//                    [--wrong-shape] [--iters N]
//
// The model must be relu(x @ w + b) with x:[batch,K], w:[K,N], b:[N] (or [1,N]
// with --bias2d; K,N default 4,3, set by --k/--n), named x/w/b -> y. Inputs are borrowed host buffers; results
// are checked against a scalar reference.
#include "max/c/common.h"
#include "max/c/context.h"
#include "max/c/device.h"
#include "max/c/model.h"
#include "max/c/tensor.h"
#include "max/c/types.h"

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

using Clock = std::chrono::steady_clock;

double msSince(Clock::time_point t0) {
  return std::chrono::duration<double, std::milli>(Clock::now() - t0).count();
}

[[noreturn]] void die(const char *what, M_Status *st) {
  std::printf("FAIL %s: %s\n", what, st ? M_getError(st) : "");
  std::exit(1);
}

struct Opts {
  const char *model = nullptr;
  bool f64 = false, bias2d = false, compileTwice = false, expectFail = false,
       wrongShape = false;
  int iters = 200;
  int64_t k = 4, n = 3;
};

M_AsyncModel *compileAndInit(M_RuntimeContext *ctx, const char *path,
                             M_Status *st, double &compileMs, double &initMs,
                             bool expectFail) {
  auto t0 = Clock::now();
  M_CompileConfig *cc = M_newCompileConfig();
  M_setModelPath(cc, path);
  M_AsyncCompiledModel *cm = M_compileModelSync(ctx, &cc, st);
  compileMs = msSince(t0);
  if (M_isError(st)) {
    if (expectFail) {
      std::printf("EXPECTED-FAIL compile (%.0f ms):\n%s\n", compileMs,
                  M_getError(st));
      std::exit(0);
    }
    die("compile", st);
  }
  if (expectFail) {
    std::printf("UNEXPECTED compile success\n");
    std::exit(1);
  }
  t0 = Clock::now();
  M_AsyncModel *m = M_initModel(ctx, cm, nullptr, st);
  if (M_isError(st))
    die("initModel", st);
  M_waitForModel(m, st);
  if (M_isError(st))
    die("waitForModel", st);
  initMs = msSince(t0);
  return m;
}

template <typename T> struct Case {
  int64_t batch;
  std::vector<T> x, w, b, ref;

  Case(int64_t n, int64_t K, int64_t N)
      : batch(n), x(n * K), w(K * N), b(N), ref(n * N) {
    for (int64_t i = 0; i < n * K; ++i)
      x[i] = T((i * 37 % 17) - 8) / T(4);
    for (int64_t i = 0; i < K * N; ++i)
      w[i] = T((i * 11 % 7) - 3) / T(2);
    for (int64_t i = 0; i < N; ++i)
      b[i] = T(i) - T(1);
    for (int64_t r = 0; r < n; ++r)
      for (int64_t c = 0; c < N; ++c) {
        T acc = b[c];
        for (int64_t k = 0; k < K; ++k)
          acc += x[r * K + k] * w[k * N + c];
        ref[r * N + c] = acc > 0 ? acc : T(0);
      }
  }
};

template <typename T>
void runCases(const Opts &o, M_RuntimeContext *ctx, M_Device *host,
              M_AsyncModel *model, M_Status *st) {
  const M_Dtype dt = o.f64 ? M_FLOAT64 : M_FLOAT32;
  for (int64_t n : {int64_t(1), int64_t(7), int64_t(1024)}) {
    Case<T> c(n, o.k, o.n);
    int64_t xs[2] = {n, o.k}, ws[2] = {o.k, o.n}, bs1[1] = {o.n}, bs2[2] = {1, o.n};
    if (o.wrongShape)
      ws[0] = 5; // borrowed buffer still 12 elements; MAX must reject
    M_TensorSpec *sx = M_newTensorSpec(xs, 2, dt, "x", host);
    M_TensorSpec *sw = M_newTensorSpec(ws, 2, dt, "w", host);
    M_TensorSpec *sb = o.bias2d ? M_newTensorSpec(bs2, 2, dt, "b", host)
                                : M_newTensorSpec(bs1, 1, dt, "b", host);

    double execMs = 0, avgMs = 0;
    const T *out = nullptr;
    size_t outN = 0;
    bool borrowedOut = false;
    M_AsyncTensorMap *outs = nullptr;
    M_AsyncTensor *y = nullptr;
    for (int it = 0; it < (n == 1024 ? o.iters : 1) + 1; ++it) {
      M_AsyncTensorMap *in = M_newAsyncTensorMap(ctx);
      M_borrowTensorInto(in, c.x.data(), sx, st);
      M_borrowTensorInto(in, c.w.data(), sw, st);
      M_borrowTensorInto(in, c.b.data(), sb, st);
      if (M_isError(st))
        die("borrow", st);
      auto t0 = Clock::now();
      if (y) {
        M_freeTensor(y);
        M_freeAsyncTensorMap(outs);
      }
      outs = M_executeModelSync(ctx, model, in, st);
      double ms = msSince(t0);
      if (M_isError(st)) {
        if (o.wrongShape) {
          std::printf("EXPECTED-FAIL execute (wrong shape): %s\n",
                      M_getError(st));
          std::exit(0);
        }
        die("execute", st);
      }
      if (it == 0)
        execMs = ms;
      else
        avgMs += ms;
      y = M_getTensorByNameFrom(outs, "y", st);
      if (M_isError(st))
        die("get y", st);
      M_freeAsyncTensorMap(in);
    }
    if (o.wrongShape) {
      std::printf("UNEXPECTED execute success with wrong shape\n");
      std::exit(1);
    }
    out = static_cast<const T *>(M_getTensorData(y));
    outN = M_getTensorNumElements(y);
    borrowedOut = (const void *)out >= (const void *)c.x.data() &&
                  (const void *)out < (const void *)(c.x.data() + c.x.size());
    M_TensorSpec *ys = M_getTensorSpec(y);
    double maxErr = 0;
    for (size_t i = 0; i < outN && i < c.ref.size(); ++i)
      maxErr = std::fmax(maxErr, std::fabs(double(out[i]) - double(c.ref[i])));
    bool ok = outN == c.ref.size() && M_getDimAt(ys, 0) == n &&
              M_getDimAt(ys, 1) == o.n && M_getDtype(ys) == dt && maxErr < 1e-5;
    std::printf("batch=%-5lld %s  first-exec=%.3f ms", (long long)n,
                ok ? "OK  " : "BAD ", execMs);
    if (n == 1024)
      std::printf("  warm-exec(avg of %d)=%.4f ms", o.iters, avgMs / o.iters);
    std::printf("  out=[%lld,%lld] maxErr=%g%s\n", (long long)M_getDimAt(ys, 0),
                (long long)M_getDimAt(ys, 1), maxErr,
                borrowedOut ? " (aliases input!)" : "");
    if (!ok)
      std::exit(1);
    M_freeTensorSpec(ys);
    M_freeTensor(y);
    M_freeAsyncTensorMap(outs);
    M_freeTensorSpec(sx);
    M_freeTensorSpec(sw);
    M_freeTensorSpec(sb);
  }
}

} // namespace

int main(int argc, char **argv) {
  Opts o;
  for (int i = 1; i < argc; ++i) {
    std::string a = argv[i];
    if (a == "--f64")
      o.f64 = true;
    else if (a == "--bias2d")
      o.bias2d = true;
    else if (a == "--compile-twice")
      o.compileTwice = true;
    else if (a == "--expect-fail")
      o.expectFail = true;
    else if (a == "--wrong-shape")
      o.wrongShape = true;
    else if (a == "--k" && i + 1 < argc)
      o.k = std::atoll(argv[++i]);
    else if (a == "--n" && i + 1 < argc)
      o.n = std::atoll(argv[++i]);
    else if (a == "--iters" && i + 1 < argc)
      o.iters = std::atoi(argv[++i]);
    else
      o.model = argv[i];
  }
  if (!o.model) {
    std::fprintf(stderr, "usage: spike MODEL.mlir [flags]\n");
    return 2;
  }

  auto t0 = Clock::now();
  M_Status *st = M_newStatus();
  M_RuntimeConfig *rc = M_newRuntimeConfig();
  M_Device *host = M_newDevice(M_HOST, 0, st);
  if (M_isError(st))
    die("newDevice", st);
  M_runtimeConfigAddDevice(rc, host);
  M_RuntimeContext *ctx = M_newRuntimeContext(rc, st);
  if (M_isError(st))
    die("newRuntimeContext", st);
  std::printf("MAX %s  context=%.0f ms  accelerators=%d\n", M_version(),
              msSince(t0), M_getAcceleratorCount());

  double cMs, iMs;
  M_AsyncModel *m = compileAndInit(ctx, o.model, st, cMs, iMs, o.expectFail);
  std::printf("compile#1=%.0f ms  init#1=%.0f ms\n", cMs, iMs);
  if (o.compileTwice) {
    M_AsyncModel *m2 = compileAndInit(ctx, o.model, st, cMs, iMs, false);
    std::printf("compile#2=%.0f ms  init#2=%.0f ms (same process)\n", cMs,
                iMs);
    M_freeModel(m2);
  }

  if (o.f64)
    runCases<double>(o, ctx, host, m, st);
  else
    runCases<float>(o, ctx, host, m, st);

  M_freeModel(m);
  M_freeRuntimeContext(ctx);
  M_freeDevice(host);
  M_freeRuntimeConfig(rc);
  M_freeStatus(st);
  std::printf("DONE\n");
  return 0;
}
