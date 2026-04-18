//===- Http.cpp - Http kernel module implementation -----------------------===//

#include "Http.hpp"
#include "KernelHelpers.hpp"
#include <string>
#include <vector>

#ifdef HTTP_CURL_AVAILABLE
#include <curl/curl.h>
#endif

#ifdef LIBZIP_AVAILABLE
#include <zip.h>
#endif

#ifdef HTTP_CURL_AVAILABLE
#include <openssl/sha.h>
#endif

namespace Eco::Kernel::Http {

#ifdef HTTP_CURL_AVAILABLE

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

    if (res != CURLE_OK) {
        std::vector<Unboxable> fields(3);
        fields[0].i = 0;
        fields[1].p = allocStringFromUTF8(std::string(curl_easy_strerror(res)));
        {
            Elm::StackRootGuard guard(&fields[1].p);
            fields[2].p = allocStringFromUTF8(urlStr);
        }
        HPointer errRec = record(fields, 0b001);
        Elm::StackRootGuard guard(&errRec);
        HPointer errVal = err(boxed(errRec), true);
        return taskSucceed(errVal);
    }

    if (statusCode >= 200 && statusCode < 300) {
        HPointer body = allocStringFromUTF8(responseBody);
        Elm::StackRootGuard guard(&body);
        HPointer okVal = ok(boxed(body), true);
        return taskSucceed(okVal);
    } else {
        std::string statusText = "HTTP " + std::to_string(statusCode);
        std::vector<Unboxable> fields(3);
        fields[0].i = static_cast<int64_t>(statusCode);
        fields[1].p = allocStringFromUTF8(statusText);
        {
            Elm::StackRootGuard guard(&fields[1].p);
            fields[2].p = allocStringFromUTF8(urlStr);
        }
        HPointer errRec = record(fields, 0b001);
        Elm::StackRootGuard guard(&errRec);
        HPointer errVal = err(boxed(errRec), true);
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

#ifdef LIBZIP_AVAILABLE
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

    // Collect file data first (no allocation yet)
    struct FileEntry { std::string content; std::string relativePath; };
    std::vector<FileEntry> entries;
    zip_int64_t numEntries = zip_get_num_entries(archive, 0);
    for (zip_int64_t i = 0; i < numEntries; ++i) {
        const char* name = zip_get_name(archive, i, 0);
        if (!name) continue;
        std::string entryName(name);
        if (!entryName.empty() && entryName.back() == '/') continue;

        zip_stat_t st;
        zip_stat_index(archive, i, 0, &st);
        zip_file_t* f = zip_fopen_index(archive, i, 0);
        if (!f) continue;

        std::string content(st.size, '\0');
        zip_fread(f, content.data(), st.size);
        zip_fclose(f);

        std::string relativePath = entryName;
        auto slashPos = relativePath.find('/');
        if (slashPos != std::string::npos) {
            relativePath = relativePath.substr(slashPos + 1);
        }
        entries.push_back({std::move(content), std::move(relativePath)});
    }

    zip_close(archive);
    zip_error_fini(&zipError);

    // Build records with rooting
    auto& rs = Allocator::instance().getRootSet();
    size_t saved = rs.stackRootPoint();
    std::vector<HPointer> fileRecords(entries.size(), listNil());
    for (auto& hp : fileRecords) rs.pushStackRoot(&hp);

    for (size_t i = 0; i < entries.size(); ++i) {
        std::vector<Unboxable> fields(2);
        fields[0].p = allocStringFromUTF8(entries[i].content);
        {
            Elm::StackRootGuard guard(&fields[0].p);
            fields[1].p = allocStringFromUTF8(entries[i].relativePath);
        }
        fileRecords[i] = record(fields, 0b00);
    }
    rs.restoreStackRootPoint(saved);

    HPointer archiveList = listFromPointers(fileRecords);
    std::vector<Unboxable> outerFields(2);
    outerFields[0].p = archiveList;
    {
        Elm::StackRootGuard guard(&outerFields[0].p);
        outerFields[1].p = allocStringFromUTF8(shaHex);
    }
    HPointer outerRec = record(outerFields, 0b00);
    Elm::StackRootGuard guard2(&outerRec);
    HPointer okVal = ok(boxed(outerRec), true);
    return taskSucceed(okVal);
#else
    // No libzip available.
    HPointer errStr = allocStringFromUTF8("Archive extraction not available (libzip not found)");
    return taskSucceed(err(boxed(errStr), true));
#endif
}

#else // !HTTP_CURL_AVAILABLE

uint64_t fetch(uint64_t /*method*/, uint64_t /*url*/, uint64_t /*headers*/) {
    return taskFailString("Http.fetch not available (libcurl not found)");
}

uint64_t getArchive(uint64_t /*url*/) {
    return taskFailString("Http.getArchive not available (libcurl not found)");
}

#endif // HTTP_CURL_AVAILABLE

} // namespace Eco::Kernel::Http
