//===- Http.cpp - Http kernel module implementation -----------------------===//

#include "Http.hpp"
#include "KernelHelpers.hpp"
#include <string>
#include <vector>

#include <curl/curl.h>
#include <zip.h>
#include <openssl/sha.h>

namespace Eco::Kernel::Http {

static size_t writeCallback(void* contents, size_t size, size_t nmemb, void* userp) {
    size_t totalSize = size * nmemb;
    auto* buffer = static_cast<std::string*>(userp);
    buffer->append(static_cast<char*>(contents), totalSize);
    return totalSize;
}

uint64_t fetch(uint64_t method, uint64_t url, uint64_t headers) {
    using namespace Elm::alloc;

    std::string methodStr = toString(method);
    std::string urlStr = toString(url);

    CURL* curl = curl_easy_init();
    if (!curl) {
        HPointer errStr = allocStringFromUTF8("Failed to initialize curl");
        return taskSucceed(err(boxed(errStr), true));
    }

    std::string responseBody;
    curl_easy_setopt(curl, CURLOPT_URL, urlStr.c_str());
    curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, methodStr.c_str());
    // The registry's POST endpoints (/all-packages, /all-packages/since) reject
    // a body-less POST with HTTP 411 Length Required. fetch carries no request
    // body, so send an explicit zero-length body to emit Content-Length: 0.
    if (methodStr == "POST") {
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, "");
        curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, 0L);
    }
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, writeCallback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &responseBody);
    curl_easy_setopt(curl, CURLOPT_ACCEPT_ENCODING, "gzip, deflate");
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);

    // Set headers from Elm List (String, String).
    struct curl_slist* curlHeaders = nullptr;
    forEachListElement(headers, [&](Unboxable head, bool /*is_boxed*/) {
        // Each element is a Tuple2 of (String, String).
        void* tuplePtr = Elm::Allocator::instance().resolve(head.p);
        Tuple2* tup = static_cast<Tuple2*>(tuplePtr);
        void* keyPtr = Elm::Allocator::instance().resolve(tup->a.p);
        void* valPtr = Elm::Allocator::instance().resolve(tup->b.p);
        std::string key = Elm::StringOps::toStdString(keyPtr);
        std::string val = Elm::StringOps::toStdString(valPtr);
        std::string headerLine = key + ": " + val;
        curlHeaders = curl_slist_append(curlHeaders, headerLine.c_str());
    });
    if (curlHeaders) {
        curl_easy_setopt(curl, CURLOPT_HTTPHEADER, curlHeaders);
    }

    CURLcode res = curl_easy_perform(curl);

    long statusCode = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &statusCode);

    curl_slist_free_all(curlHeaders);
    curl_easy_cleanup(curl);

    // Eco.Http.fetch (Eco/Http.elm) destructures the Err payload as a Tuple2
    // ( statusCode, statusText ) and adds `url` itself, so build a Tuple2 (NOT a
    // record). Mask 0x1: slot 0 = unboxed Int, slot 1 = boxed String.
    if (res != CURLE_OK) {
        HPointer statusText = allocStringFromUTF8(std::string(curl_easy_strerror(res)));
        Elm::StackRootGuard guard(&statusText);
        // statusCode 0 signals a transport-level failure (no HTTP response).
        HPointer errTuple = tuple2(unboxedInt(0), boxed(statusText), 0x1);
        Elm::StackRootGuard tupleGuard(&errTuple);
        HPointer errVal = err(boxed(errTuple), true);
        return taskSucceed(errVal);
    }

    if (statusCode >= 200 && statusCode < 300) {
        HPointer body = allocStringFromUTF8(responseBody);
        Elm::StackRootGuard guard(&body);
        HPointer okVal = ok(boxed(body), true);
        return taskSucceed(okVal);
    } else {
        HPointer statusText = allocStringFromUTF8("HTTP " + std::to_string(statusCode));
        Elm::StackRootGuard guard(&statusText);
        HPointer errTuple = tuple2(unboxedInt(static_cast<int64_t>(statusCode)),
                                   boxed(statusText), 0x1);
        Elm::StackRootGuard tupleGuard(&errTuple);
        HPointer errVal = err(boxed(errTuple), true);
        return taskSucceed(errVal);
    }
}

uint64_t getArchive(uint64_t url) {
    using namespace Elm::alloc;

    std::string urlStr = toString(url);

    // Download the archive.
    CURL* curl = curl_easy_init();
    if (!curl) {
        HPointer errStr = allocStringFromUTF8("Failed to initialize curl");
        return taskSucceed(err(boxed(errStr), true));
    }

    std::string zipData;
    curl_easy_setopt(curl, CURLOPT_URL, urlStr.c_str());
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, writeCallback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &zipData);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);

    CURLcode res = curl_easy_perform(curl);
    curl_easy_cleanup(curl);

    if (res != CURLE_OK) {
        HPointer errStr = allocStringFromUTF8(std::string(curl_easy_strerror(res)));
        return taskSucceed(err(boxed(errStr), true));
    }

    // Compute SHA1 hash.
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

    // Extract ZIP using libzip.
    zip_error_t zipError;
    zip_error_init(&zipError);
    zip_source_t* src = zip_source_buffer_create(zipData.data(), zipData.size(), 0, &zipError);
    if (!src) {
        zip_error_fini(&zipError);
        HPointer errStr = allocStringFromUTF8("Failed to create zip source");
        return taskSucceed(err(boxed(errStr), true));
    }

    zip_t* archive = zip_open_from_source(src, ZIP_RDONLY, &zipError);
    if (!archive) {
        zip_source_free(src);
        zip_error_fini(&zipError);
        HPointer errStr = allocStringFromUTF8("Failed to open zip archive");
        return taskSucceed(err(boxed(errStr), true));
    }

    // Collect file data first (no allocation yet). Match the JS kernel
    // (Eco/Kernel/Http.js): return each entry's FULL name including the GitHub
    // wrapper directory, and keep directory entries (with empty content).
    // Builder/File.elm writePackage strips the wrapper prefix itself, using the
    // first entry as the root — so stripping the leading component or dropping
    // directory entries here would leave it nothing to extract.
    struct FileEntry { std::string content; std::string relativePath; };
    std::vector<FileEntry> entries;
    zip_int64_t numEntries = zip_get_num_entries(archive, 0);
    for (zip_int64_t i = 0; i < numEntries; ++i) {
        const char* name = zip_get_name(archive, i, 0);
        if (!name) continue;
        std::string entryName(name);

        std::string content;
        bool isDir = !entryName.empty() && entryName.back() == '/';
        if (!isDir) {
            zip_stat_t st;
            zip_stat_index(archive, i, 0, &st);
            zip_file_t* f = zip_fopen_index(archive, i, 0);
            if (!f) continue;
            content.resize(st.size);
            zip_fread(f, content.data(), st.size);
            zip_fclose(f);
        }
        entries.push_back({std::move(content), std::move(entryName)});
    }

    zip_close(archive);
    zip_error_fini(&zipError);

    // Build the result with rooting. Eco.Http.getArchive (Eco/Http.elm)
    // destructures the kernel result as tuples: outer `( sha, entries )` and
    // each entry `( relativePath, data )`. So build Tuple2 values (NOT records)
    // with that exact field order.
    auto& rs = Allocator::instance().getRootSet();
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
        // ( relativePath, data )
        fileTuples[i] = tuple2(boxed(rel), boxed(data), 0);
    }
    rs.restoreStackRangePoint(saved);

    HPointer archiveList = listFromPointers(fileTuples);
    HPointer sha = listNil();
    {
        Elm::StackRootGuard guard(&archiveList);
        sha = allocStringFromUTF8(shaHex);
    }
    Elm::StackRootGuard guard2(&archiveList, &sha);
    // ( sha, archive )
    HPointer outerTuple = tuple2(boxed(sha), boxed(archiveList), 0);
    Elm::StackRootGuard guard3(&outerTuple);
    HPointer okVal = ok(boxed(outerTuple), true);
    return taskSucceed(okVal);
}

} // namespace Eco::Kernel::Http
