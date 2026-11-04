//===- Http.cpp - Http kernel module implementation -----------------------===//
//
// Both kernels are async-park bindings. When the Task runs, its body copies the request out of the heap, parks a
// *bundle* with the scheduler, and submits the request to `HttpService` on the *eco lane*, the result queue that
// `HttpService` keeps apart from elm/http's. The bundle is a heap Custom whose constructor tag says which kernel
// made it (`KIND_FETCH` or `KIND_GET_ARCHIVE`) and whose one field is the resume closure; parking it keeps it
// rooted and acquires a hold, under a token that travels with the request.
//
// One async source, `ecoHttpDrain`, serves both kernels. It pops each result on the eco thread, takes the bundle
// back by its token, builds the response the bundle's tag calls for (the SHA-1 and the unzipping happen here, on
// the eco thread), resumes the Task with it and releases the hold.
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
// Windows uses CNG (BCrypt) for SHA-1 instead of OpenSSL. The shim below has the signature of OpenSSL's one-shot
// `SHA1()`, so the code that calls it is the same on every platform.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <bcrypt.h>
#include <climits>
#pragma comment(lib, "bcrypt.lib")
namespace { constexpr int SHA_DIGEST_LENGTH = 20; } // Bytes in a SHA-1 digest, as OpenSSL names it.
namespace {
// Writes the SHA-1 digest of the `len` bytes at `data` to `out` and returns `out`. The input is fed to the hash
// in pieces of at most `ULONG_MAX` bytes, since one `BCryptHashData` call takes a `ULONG` length. Writes 20 zero
// bytes when any CNG call fails, so the digest is still defined; it then matches no real archive's hash.
inline unsigned char* SHA1(const unsigned char* data, size_t len,
                            unsigned char out[20]) {
    BCRYPT_ALG_HANDLE alg = nullptr;
    BCRYPT_HASH_HANDLE hash = nullptr;
    bool ok = BCRYPT_SUCCESS(BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA1_ALGORITHM, nullptr, 0)) &&
              BCRYPT_SUCCESS(BCryptCreateHash(alg, &hash, nullptr, 0, nullptr, 0, 0));
    while (ok && len > 0) {
        ULONG chunk = static_cast<ULONG>(len > ULONG_MAX ? ULONG_MAX : len);
        ok = BCRYPT_SUCCESS(BCryptHashData(hash, const_cast<PUCHAR>(data), chunk, 0));
        data += chunk;
        len -= chunk;
    }
    ok = ok && BCRYPT_SUCCESS(BCryptFinishHash(hash, out, 20, 0));
    if (hash) BCryptDestroyHash(hash);
    if (alg) BCryptCloseAlgorithmProvider(alg, 0);
    if (!ok) {
        for (int i = 0; i < 20; ++i) out[i] = 0;
    }
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

// The bundle constructor tag of a `fetch` request. The drain reads it to choose the response builder.
constexpr uint16_t KIND_FETCH       = 0xEC01;
// The bundle constructor tag of a `getArchive` request.
constexpr uint16_t KIND_GET_ARCHIVE = 0xEC02;

// ----- Request helpers ----------------------------------------------------

// Returns copies of the `(name, value)` String tuples in the Elm List whose word is `headersEnc`, in order.
//
// Does not allocate on the Elm heap, but walks the list through raw pointers, so the list must not move while it
// runs: the caller must not allocate between decoding the list and this call.
std::vector<std::pair<std::string, std::string>>
listOfTuplesToHeaders(uint64_t headersEnc) {
    std::vector<std::pair<std::string, std::string>> result;
    auto& allocator = Elm::Allocator::instance();
    for (Elm::alloc::ListCursor c(Export::decode(headersEnc)); !c.done();
         c.next()) {
        Tuple2* tup = static_cast<Tuple2*>(allocator.resolve(c.current().p));
        std::string key = toString(Export::encode(tup->a.p));
        std::string val = toString(Export::encode(tup->b.p));
        result.push_back({std::move(key), std::move(val)});
    }
    return result;
}

// ----- KIND_FETCH response builder ----------------------------------------

// Returns the `Result` a `fetch` Task succeeds with for the transfer outcome `r`, as `Http.hpp` describes on
// `fetch`. A GC point.
HPointer buildFetchResponse(const HttpService::Result& r) {
    using EK = HttpService::ErrorKind;
    ECO_KLOG("http", "fetch result token=%lu err=%d status=%ld body=%zuB",
             (unsigned long)r.token, (int)r.error, r.status, r.body.size());
    if (r.error != EK::Ok) {
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

// Returns the `Result` a `getArchive` Task succeeds with for the transfer outcome `r`, as `Http.hpp` describes on
// `getArchive`. Hashes and unzips the body. A GC point.
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

    // Redirects have been followed, so this is the final response's status. An error page is not the archive,
    // even when its body happens to be a ZIP file.
    if (r.status < 200 || r.status > 299) {
        ECO_KLOG("http", "getArchive http-error status=%ld", r.status);
        HPointer errStr = allocStringFromUTF8("HTTP " + std::to_string(r.status));
        Elm::StackRootGuard g(&errStr);
        return err(boxed(errStr), true);
    }

    const std::string& zipData = r.body;

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

    // The archive is read in full into C++ strings first, so no heap allocation happens while libzip is open.
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

    // An entry that cannot be stat'ed, opened or read in full makes the whole archive unreadable: a package
    // with a missing or truncated file is corrupt. The message is kept here and turned into an Elm String only
    // once libzip is closed.
    struct FileEntry { std::string content; std::string relativePath; };
    std::vector<FileEntry> entries;
    std::string failure;
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
        if (zip_stat_index(archive, i, 0, &st) != 0 || !(st.valid & ZIP_STAT_SIZE)) {
            ECO_KLOG("http", "zip entry-stat-fail name=%s msg=%s",
                     entryName.c_str(), zip_strerror(archive));
            failure = "Failed to stat zip entry " + entryName;
            break;
        }
        ECO_KLOG("http", "zip entry idx=%lld name=%s isDir=%d size=%lluB",
                 (long long)i, entryName.c_str(), (int)isDir,
                 (unsigned long long)st.size);
        if (!isDir) {
            zip_file_t* f = zip_fopen_index(archive, i, 0);
            if (!f) {
                ECO_KLOG("http", "zip entry-open-fail name=%s msg=%s",
                         entryName.c_str(),
                         zip_strerror(archive));
                failure = "Failed to open zip entry " + entryName;
                break;
            }
            content.resize(st.size);
            zip_int64_t got = zip_fread(f, content.data(), st.size);
            zip_fclose(f);
            if (got != (zip_int64_t)st.size) {
                ECO_KLOG("http",
                         "zip entry-short-read name=%s want=%zu got=%lld",
                         entryName.c_str(), (size_t)st.size, (long long)got);
                failure = "Failed to read zip entry " + entryName;
                break;
            }
        }
        entries.push_back({std::move(content), std::move(entryName)});
    }
    zip_close(archive);
    zip_error_fini(&zipError);
    if (!failure.empty()) {
        HPointer errStr = allocStringFromUTF8(failure);
        Elm::StackRootGuard g(&errStr);
        return err(boxed(errStr), true);
    }

    auto& rs = Elm::Allocator::instance().getRootSet();
    size_t saved = rs.stackRangePoint();
    std::vector<HPointer> fileTuples(entries.size(), listNil());
    // One all-boxed root range covers the presized buffer. Slots not yet filled hold the Nil constant, which the
    // GC skips.
    rs.pushStackRootRange(fileTuples.data(), fileTuples.size(), ~0ULL);

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

// Resumes the Task of every result waiting on the eco lane, as the file comment describes, and releases each
// result's hold. A result whose bundle is gone has its hold released and nothing resumed; a bundle with an
// unknown tag resumes its Task with Unit.
void ecoHttpDrain() {
    auto& sched = Elm::Platform::Scheduler::instance();
    HttpService::Result r;
    while (HttpService::instance().tryPopResultEcoLane(r)) {
        HPointer bundle = sched.takePendingResume(r.token);
        if (isNil(bundle)) {
            sched.releaseHold(r.token);
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
        sched.releaseHold(r.token);
    }
}

// Registers `ecoHttpDrain` as an async source, ready while the eco lane has results, the first time it is called.
void ensureRegistered() {
    static std::once_flag flag;
    std::call_once(flag, [] {
        Elm::Platform::Scheduler::instance().registerAsyncSource(
            ecoHttpDrain,
            [] { return HttpService::instance().hasReadyResultsEcoLane(); });
    });
}

// Parks a bundle with constructor tag `kind` holding `resume`, acquiring a Task hold, and returns its token. A GC
// point.
uint64_t parkBundle(uint16_t kind, HPointer resume) {
    Elm::StackRootGuard rg(&resume);
    std::vector<Elm::Unboxable> fields(1);
    fields[0] = boxed(resume);
    HPointer bundle = custom(kind, fields, /*unboxed_mask=*/0);
    auto& sched = Elm::Platform::Scheduler::instance();
    uint64_t token = sched.parkResume(bundle, Elm::Platform::HoldKind::Task, "Eco.Http");
    return token;
}

// ----- Async-park bindings -------------------------------------------------

// Sends the `fetch` request in `captured`, a Tuple3 of the method, URL and headers, and parks `resume` to receive
// its result. Returns Unit as the kill handle, so a kill does not cancel the request.
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
    // A body-less POST/PUT/PATCH gets `Content-Length: 0` from HttpService (CURLOPT_POSTFIELDSIZE 0).
    req.eco_lane = true;
    HttpService::instance().submit(std::move(req));

    return unit();  // kill handle
}

// Sends a `GET` for the archive at the URL String `captured`, and parks `resume` to receive its result. Returns
// Unit as the kill handle, so a kill does not cancel the request.
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
