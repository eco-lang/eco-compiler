//===- Http.cpp - Http kernel module implementation -----------------------===//
//
// Per KERNEL_TASK_IO_001 / plans/defer-eager-kernel-tasks-via-binding.md
// Phase 5: `Eco.Http.fetch` and `Eco.Http.getArchive` are returned as
// Task_Bindings. The blocking `curl_easy_perform` is now run on an
// HttpService worker thread (Q10 — extend the existing service, don't fork
// a parallel one); the main-thread drain pops the worker's result, runs the
// libzip / SHA1 post-process step (still on the main thread), builds the
// Eco-shape response, and resumes the parked binding.
//
// Bundle layout in the scheduler's pendingResumes_ registry:
//
//   Custom { ctor = KIND_FETCH | KIND_GET_ARCHIVE, values = [resume] }
//
// The single shared async-source drain (`ecoHttpDrain`) reads the bundle's
// ctor to decide which response builder to use.
//
//===----------------------------------------------------------------------===//

#include "Http.hpp"
#include "KernelDebug.hpp"
#include "KernelHelpers.hpp"
#include "TaskBinding.hpp"
#include "allocator/RootSet.hpp"
#include "platform/HttpService.hpp"
#include "platform/Scheduler.hpp"
#include <mutex>
#include <string>
#include <vector>

#if defined(_WIN32)
// Use Windows CNG (BCrypt) for SHA-1 — see plans/build-on-windows.md
// (Dependency stack: OpenSSL eliminated on Windows). The shim below
// matches OpenSSL's SHA1() one-shot signature so existing call sites
// don't change.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <bcrypt.h>
#pragma comment(lib, "bcrypt.lib")
namespace { constexpr int SHA_DIGEST_LENGTH = 20; }
namespace {
inline unsigned char* SHA1(const unsigned char* data, size_t len,
                            unsigned char out[20]) {
    BCRYPT_ALG_HANDLE h = nullptr;
    if (BCryptOpenAlgorithmProvider(&h, BCRYPT_SHA1_ALGORITHM, nullptr, 0) != 0) {
        // On failure, zero-fill the digest so the caller's hex-encoding
        // path stays well-defined; the caller compares the digest by
        // value, so an all-zero hash will simply mismatch the registry's
        // recorded SHA and be reported as a corrupt archive.
        for (int i = 0; i < 20; ++i) out[i] = 0;
        return out;
    }
    BCryptHash(h, nullptr, 0,
               const_cast<PUCHAR>(data),
               static_cast<ULONG>(len > 0xffffffff ? 0xffffffff : len),
               out, 20);
    BCryptCloseAlgorithmProvider(h, 0);
    return out;
}
}
#else
#include <openssl/sha.h>
#endif
#include <zip.h>

namespace Eco::Kernel::Http {

using Elm::HPointer;
using namespace Elm::alloc;
using Elm::Platform::HttpService;

namespace {

// Bundle ctor tags for the pendingResume registry. Distinct values let the
// shared drain dispatch by ctor without an extra side table. Picked high to
// avoid collision with any compiler-generated tag.
constexpr uint16_t KIND_FETCH       = 0xEC01;
constexpr uint16_t KIND_GET_ARCHIVE = 0xEC02;

// ----- Helpers shared between drain dispatch branches ---------------------

// Walk an Elm `List (Tuple2 String String)` headers list into a POD
// vector<{key, value}> on the main thread (binding step). Runs ONLY before
// any allocation; the snapshotted strings are kept by-value.
std::vector<std::pair<std::string, std::string>>
listOfTuplesToHeaders(uint64_t headersEnc) {
    std::vector<std::pair<std::string, std::string>> result;
    HPointer current = Export::decode(headersEnc);
    auto& allocator = Elm::Allocator::instance();
    while (!isConstant(current) || current.constant != Elm::Const_Nil + 1) {
        Cons* cell = static_cast<Cons*>(allocator.resolve(current));
        Tuple2* tup = static_cast<Tuple2*>(allocator.resolve(cell->head.p));
        std::string key = toString(Export::encode(tup->a.p));
        std::string val = toString(Export::encode(tup->b.p));
        result.push_back({std::move(key), std::move(val)});
        current = cell->tail;
    }
    return result;
}

// ----- KIND_FETCH response builder ----------------------------------------

// Eco.Http.fetch destructures the Err payload as a Tuple2 (statusCode,
// statusText) and the Ok payload as a String body. Mirrors the pre-Phase-5
// eager implementation's exact shape.
HPointer buildFetchResponse(const HttpService::Result& r) {
    using EK = HttpService::ErrorKind;
    ECO_KLOG("http", "fetch result token=%lu err=%d status=%ld body=%zuB",
             (unsigned long)r.token, (int)r.error, r.status, r.body.size());
    if (r.error != EK::Ok) {
        // Transport-level failures: surface a Tuple2 (0, curl-strerror-ish).
        // Mirrors the pre-Phase-5 path which mapped CURLE_* to a single
        // "transport failure" with statusCode=0.
        const char* msg = "Network error";
        switch (r.error) {
            case EK::Timeout:      msg = "Request timed out"; break;
            case EK::BadUrl:       msg = "Bad URL"; break;
            case EK::NetworkError: msg = "Network error"; break;
            default: break;
        }
        ECO_KLOG("http", "fetch error msg=%s", msg);
        HPointer statusText = allocStringFromUTF8(msg);
        Elm::StackRootGuard g(&statusText);
        HPointer errTuple = tuple2(unboxedInt(0), boxed(statusText), 0x1);
        Elm::StackRootGuard tg(&errTuple);
        return err(boxed(errTuple), true);
    }

    if (r.status >= 200 && r.status < 300) {
        HPointer body = allocStringFromUTF8(r.body);
        Elm::StackRootGuard g(&body);
        return ok(boxed(body), true);
    }

    ECO_KLOG("http", "fetch http-error status=%ld statusText=%s",
             r.status, r.statusText.c_str());
    HPointer statusText = allocStringFromUTF8(
        r.statusText.empty() ? std::string("HTTP " + std::to_string(r.status))
                              : r.statusText);
    Elm::StackRootGuard g(&statusText);
    HPointer errTuple = tuple2(unboxedInt(static_cast<int64_t>(r.status)),
                                boxed(statusText), 0x1);
    Elm::StackRootGuard tg(&errTuple);
    return err(boxed(errTuple), true);
}

// ----- KIND_GET_ARCHIVE response builder ----------------------------------

// Run libzip + SHA1 on the body bytes and build the Eco-level success value:
//   Ok (sha, [(relativePath, content)]). Mirrors the pre-Phase-5 eager path
//   in `Eco.Http.getArchive`.
HPointer buildGetArchiveResponse(const HttpService::Result& r) {
    ECO_KLOG("http", "getArchive result token=%lu err=%d status=%ld body=%zuB",
             (unsigned long)r.token, (int)r.error, r.status, r.body.size());
    if (r.error != HttpService::ErrorKind::Ok) {
        const char* msg = "Network error";
        switch (r.error) {
            case HttpService::ErrorKind::Timeout:      msg = "Request timed out"; break;
            case HttpService::ErrorKind::BadUrl:       msg = "Bad URL"; break;
            case HttpService::ErrorKind::NetworkError: msg = "Network error"; break;
            default: break;
        }
        ECO_KLOG("http", "getArchive error msg=%s", msg);
        HPointer errStr = allocStringFromUTF8(msg);
        Elm::StackRootGuard g(&errStr);
        return err(boxed(errStr), true);
    }

    const std::string& zipData = r.body;

    // SHA1.
    std::string shaHex;
    {
        unsigned char hash[SHA_DIGEST_LENGTH];
        SHA1(reinterpret_cast<const unsigned char*>(zipData.data()),
             zipData.size(), hash);
        char hex[SHA_DIGEST_LENGTH * 2 + 1];
        for (int i = 0; i < SHA_DIGEST_LENGTH; ++i) {
            snprintf(hex + i * 2, 3, "%02x", hash[i]);
        }
        shaHex = std::string(hex, SHA_DIGEST_LENGTH * 2);
    }
    ECO_KLOG("http", "zip sha=%s size=%zuB", shaHex.c_str(), zipData.size());

    // libzip extract — same logic as the pre-Phase-5 eager `getArchive`.
    zip_error_t zipError;
    zip_error_init(&zipError);
    zip_source_t* src = zip_source_buffer_create(
        zipData.data(), zipData.size(), 0, &zipError);
    if (!src) {
        ECO_KLOG("http", "zip source-create-fail msg=%s",
                 zip_error_strerror(&zipError));
        zip_error_fini(&zipError);
        HPointer errStr = allocStringFromUTF8("Failed to create zip source");
        Elm::StackRootGuard g(&errStr);
        return err(boxed(errStr), true);
    }
    zip_t* archive = zip_open_from_source(src, ZIP_RDONLY, &zipError);
    if (!archive) {
        ECO_KLOG("http", "zip open-fail msg=%s zip_err=%d sys_err=%d",
                 zip_error_strerror(&zipError),
                 zip_error_code_zip(&zipError),
                 zip_error_code_system(&zipError));
        zip_source_free(src);
        zip_error_fini(&zipError);
        HPointer errStr = allocStringFromUTF8("Failed to open zip archive");
        Elm::StackRootGuard g(&errStr);
        return err(boxed(errStr), true);
    }

    struct FileEntry { std::string content; std::string relativePath; };
    std::vector<FileEntry> entries;
    zip_int64_t numEntries = zip_get_num_entries(archive, 0);
    ECO_KLOG("http", "zip open entries=%lld", (long long)numEntries);
    for (zip_int64_t i = 0; i < numEntries; ++i) {
        const char* name = zip_get_name(archive, i, 0);
        if (!name) {
            ECO_KLOG("http", "zip entry idx=%lld name=<null>",
                     (long long)i);
            continue;
        }
        std::string entryName(name);
        std::string content;
        bool isDir = !entryName.empty() && entryName.back() == '/';
        zip_stat_t st;
        zip_stat_index(archive, i, 0, &st);
        ECO_KLOG("http", "zip entry idx=%lld name=%s isDir=%d size=%lluB",
                 (long long)i, entryName.c_str(), (int)isDir,
                 (unsigned long long)st.size);
        if (!isDir) {
            zip_file_t* f = zip_fopen_index(archive, i, 0);
            if (!f) {
                ECO_KLOG("http", "zip entry-open-fail name=%s msg=%s",
                         entryName.c_str(),
                         zip_strerror(archive));
                continue;
            }
            content.resize(st.size);
            zip_int64_t got = zip_fread(f, content.data(), st.size);
            if (got != (zip_int64_t)st.size) {
                ECO_KLOG("http",
                         "zip entry-short-read name=%s want=%zu got=%lld",
                         entryName.c_str(), (size_t)st.size, (long long)got);
            }
            zip_fclose(f);
        }
        entries.push_back({std::move(content), std::move(entryName)});
    }
    zip_close(archive);
    zip_error_fini(&zipError);

    // Build Eco-shape result: Ok (sha, [(relativePath, data)]).
    auto& rs = Elm::Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();
    std::vector<HPointer> fileTuples(entries.size(), listNil());
    for (auto& hp : fileTuples) rs.pushStackRootRange(&hp, 1, 1);

    for (size_t i = 0; i < entries.size(); ++i) {
        HPointer rel = allocStringFromUTF8(entries[i].relativePath);
        HPointer data = listNil();
        {
            Elm::StackRootGuard guard(&rel);
            data = allocStringFromUTF8(entries[i].content);
        }
        Elm::StackRootGuard guard(&rel, &data);
        fileTuples[i] = tuple2(boxed(rel), boxed(data), 0);
    }
    rs.restoreStackRangePoint(saved);

    HPointer archiveList = listFromPointers(fileTuples);
    HPointer sha = listNil();
    {
        Elm::StackRootGuard g(&archiveList);
        sha = allocStringFromUTF8(shaHex);
    }
    Elm::StackRootGuard g2(&archiveList, &sha);
    HPointer outerTuple = tuple2(boxed(sha), boxed(archiveList), 0);
    Elm::StackRootGuard g3(&outerTuple);
    return ok(boxed(outerTuple), true);
}

// ----- Shared async-source drain ------------------------------------------

void ecoHttpDrain() {
    auto& sched = Elm::Platform::Scheduler::instance();
    HttpService::Result r;
    while (HttpService::instance().tryPopResultEcoLane(r)) {
        HPointer bundle = sched.takePendingResume(r.token);
        if (isNil(bundle)) {
            sched.decrementPendingAsync();
            continue;
        }
        Elm::StackRootGuard bundleRoot(&bundle);

        uint16_t kind;
        HPointer resume;
        {
            Custom* b = static_cast<Custom*>(
                Elm::Allocator::instance().resolve(bundle));
            kind = static_cast<uint16_t>(b->ctor);
            resume = b->values[0].p;
        }
        Elm::StackRootGuard resumeRoot(&resume);

        HPointer payload = listNil();
        {
            Elm::StackRootGuard payloadRoot(&payload);
            ECO_KLOG("http", "drain kind=%s token=%lu",
                     kind == KIND_FETCH ? "FETCH" :
                     kind == KIND_GET_ARCHIVE ? "GET_ARCHIVE" : "?",
                     (unsigned long)r.token);
            switch (kind) {
                case KIND_FETCH:
                    payload = buildFetchResponse(r);
                    break;
                case KIND_GET_ARCHIVE:
                    payload = buildGetArchiveResponse(r);
                    break;
                default:
                    payload = unit();
                    break;
            }
            HPointer task = sched.taskSucceed(payload);
            Elm::StackRootGuard taskRoot(&task);
            Elm::Platform::Scheduler::callClosure1(resume, task);
        }
        sched.decrementPendingAsync();
    }
}

void ensureRegistered() {
    static std::once_flag flag;
    std::call_once(flag, [] {
        Elm::Platform::Scheduler::instance().registerAsyncSource(
            ecoHttpDrain,
            [] { return HttpService::instance().hasReadyResultsEcoLane(); });
    });
}

// Allocate a bundle Custom (ctor=kind, values=[resume]) and register it as
// the pendingResume for `resume`'s token. Returns the token.
uint64_t parkBundle(uint16_t kind, HPointer resume) {
    Elm::StackRootGuard rg(&resume);
    std::vector<Elm::Unboxable> fields(1);
    fields[0] = boxed(resume);
    HPointer bundle = custom(kind, fields, /*unboxed_mask=*/0);
    auto& sched = Elm::Platform::Scheduler::instance();
    uint64_t token = sched.registerPendingResume(bundle);
    sched.incrementPendingAsync();
    return token;
}

// ----- Async-park bindings -------------------------------------------------

// Captured payload for fetch: tuple3(method, url, headers).
HPointer fetchBody(HPointer captured, HPointer resume) {
    HPointer methodHP, urlHP, headersHP;
    {
        Tuple3* tup = static_cast<Tuple3*>(
            Elm::Allocator::instance().resolve(captured));
        methodHP  = tup->a.p;
        urlHP     = tup->b.p;
        headersHP = tup->c.p;
    }
    std::string method = toString(Export::encode(methodHP));
    std::string url    = toString(Export::encode(urlHP));
    auto hdrs = listOfTuplesToHeaders(Export::encode(headersHP));

    ensureRegistered();
    uint64_t token = parkBundle(KIND_FETCH, resume);
    ECO_KLOG("http", "fetch submit method=%s url=%s headers=%zu token=%lu",
             method.c_str(), url.c_str(), hdrs.size(), (unsigned long)token);

    HttpService::Request req;
    req.token = token;
    req.method = method;
    req.url = url;
    req.headers = std::move(hdrs);
    // Pre-Phase-5 eager path always set Content-Length: 0 for body-less
    // POSTs because the package registry rejects them with 411. Preserve.
    if (method == "POST") {
        req.body = "";  // forces COPYPOSTFIELDS path with size=0
        req.contentType = "";
    }
    req.eco_lane = true;
    HttpService::instance().submit(std::move(req));

    return unit();  // kill handle
}

// Captured payload for getArchive: the URL HPointer.
HPointer getArchiveBody(HPointer captured, HPointer resume) {
    std::string url = toString(Export::encode(captured));

    ensureRegistered();
    uint64_t token = parkBundle(KIND_GET_ARCHIVE, resume);
    ECO_KLOG("http", "getArchive submit url=%s token=%lu",
             url.c_str(), (unsigned long)token);

    HttpService::Request req;
    req.token = token;
    req.method = "GET";
    req.url = url;
    req.eco_lane = true;
    HttpService::instance().submit(std::move(req));

    return unit();  // kill handle
}

} // anonymous namespace

uint64_t fetch(uint64_t method, uint64_t url, uint64_t headers) {
    HPointer methodHP = Export::decode(method);
    HPointer urlHP = Export::decode(url);
    HPointer headersHP = Export::decode(headers);
    Elm::StackRootGuard g(&methodHP, &urlHP, &headersHP);
    HPointer payload = tuple3(
        boxed(methodHP), boxed(urlHP), boxed(headersHP), /*unboxed_mask=*/0);
    return Export::encode(
        Elm::Platform::makeAsyncBinding<fetchBody>(payload));
}

uint64_t getArchive(uint64_t url) {
    return Export::encode(
        Elm::Platform::makeAsyncBinding<getArchiveBody>(Export::decode(url)));
}

} // namespace Eco::Kernel::Http
