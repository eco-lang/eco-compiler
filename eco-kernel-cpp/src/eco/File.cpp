//===- File.cpp - File kernel module implementation -----------------------===//
//
// Per KERNEL_TASK_IO_001 / plans/defer-eager-kernel-tasks-via-binding.md
// Phase 3: every Task-returning File kernel is wrapped in a Task_Binding so
// the syscall fires when the scheduler steps the binding, not at the kernel
// call site. The synchronous IO bodies live in anonymous-namespace helpers
// keyed by name (`*Body`); the exported `Eco::Kernel::File::*` functions are
// thin binding-creation wrappers.
//
// Capture packing convention (Q2 — no kind-inferred templates):
//   * 1-arg HPointer kernel: captured = the HPointer directly.
//   * 1-arg unboxed-Int kernel: captured = tuple2(unboxedInt(i), unit, 0x1).
//     Slot 1 holds unit() as a no-op placeholder so we can keep using the
//     existing tuple2 alloc helper.
//   * 2-arg both-HPointer: captured = tuple2(boxed(a), boxed(b), 0).
//   * 2-arg (HPointer, Int): captured = tuple2(boxed(a), unboxedInt(i), 0x4).
//     mask bit pattern: 2 bits per slot, slot 1 unboxed Int = (01 << 2) = 0x4.
//   * 2-arg (Int, HPointer): captured = tuple2(unboxedInt(i), boxed(b), 0x1).
//
//===----------------------------------------------------------------------===//

#include "File.hpp"
#include "KernelDebug.hpp"
#include "KernelHelpers.hpp"
#include "TaskBinding.hpp"
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <dirent.h>
#include <fcntl.h>
#include <fstream>
#include <filesystem>
#include <sstream>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

namespace Eco::Kernel::File {

namespace {

// Tuple unpack helpers (Q2 — explicit HPointer-centric, no inference).
inline Tuple2* asTuple2(HPointer captured) {
    return static_cast<Tuple2*>(Elm::Allocator::instance().resolve(captured));
}

// --- 1-arg-HPointer bodies ----------------------------------------------------

HPointer readStringBody(HPointer captured) {
    std::string pathStr = toString(Export::encode(captured));
    ECO_KLOG("file", "readString start path=%s", pathStr.c_str());
    std::ifstream file(pathStr);
    if (!file) {
        int err = errno;
        ECO_KLOG("file", "readString fail path=%s errno=%d msg=%s",
                 pathStr.c_str(), err, std::strerror(err));
        return failErrno(err, pathStr, "could not open file for reading");
    }
    std::ostringstream ss;
    ss << file.rdbuf();
    std::string contents = ss.str();
    ECO_KLOG("file", "readString done path=%s size=%zu",
             pathStr.c_str(), contents.size());
    return succeedString(std::move(contents));
}

HPointer readBytesBody(HPointer captured) {
    std::string pathStr = toString(Export::encode(captured));
    ECO_KLOG("file", "readBytes start path=%s", pathStr.c_str());
    std::ifstream file(pathStr, std::ios::binary | std::ios::ate);
    if (!file) {
        int err = errno;
        ECO_KLOG("file", "readBytes fail path=%s errno=%d msg=%s",
                 pathStr.c_str(), err, std::strerror(err));
        return failErrno(err, pathStr, "could not open file for reading");
    }
    auto size = file.tellg();
    file.seekg(0, std::ios::beg);
    std::vector<uint8_t> buffer(static_cast<size_t>(size));
    file.read(reinterpret_cast<char*>(buffer.data()), size);
    ECO_KLOG("file", "readBytes done path=%s size=%zu",
             pathStr.c_str(), buffer.size());
    HPointer bytes = Elm::alloc::allocByteBuffer(buffer.data(), buffer.size());
    return succeed(bytes);
}

HPointer fileExistsBody(HPointer captured) {
    std::string pathStr = toString(Export::encode(captured));
    struct stat st;
    bool exists = (stat(pathStr.c_str(), &st) == 0 && S_ISREG(st.st_mode));
    ECO_KLOG("file", "fileExists path=%s result=%d",
             pathStr.c_str(), (int)exists);
    return succeedBool(exists);
}

HPointer dirExistsBody(HPointer captured) {
    std::string pathStr = toString(Export::encode(captured));
    struct stat st;
    bool exists = (stat(pathStr.c_str(), &st) == 0 && S_ISDIR(st.st_mode));
    ECO_KLOG("file", "dirExists path=%s result=%d",
             pathStr.c_str(), (int)exists);
    return succeedBool(exists);
}

HPointer findExecutableBody(HPointer captured) {
    std::string nameStr = toString(Export::encode(captured));
    ECO_KLOG("file", "findExecutable start name=%s", nameStr.c_str());
    const char* pathEnv = std::getenv("PATH");
    if (!pathEnv) {
        ECO_KLOG("file", "findExecutable done name=%s result=none (no PATH)",
                 nameStr.c_str());
        return succeed(Elm::alloc::nothing());
    }
    std::string pathStr(pathEnv);
    size_t pos = 0;
    while (pos < pathStr.size()) {
        size_t sep = pathStr.find(':', pos);
        if (sep == std::string::npos) {
            sep = pathStr.size();
        }
        std::string dir = pathStr.substr(pos, sep - pos);
        std::string fullPath = dir + "/" + nameStr;
        if (access(fullPath.c_str(), X_OK) == 0) {
            ECO_KLOG("file", "findExecutable done name=%s result=%s",
                     nameStr.c_str(), fullPath.c_str());
            HPointer str = Elm::alloc::allocStringFromUTF8(fullPath);
            return succeed(Elm::alloc::just(Elm::alloc::boxed(str), true));
        }
        pos = sep + 1;
    }
    ECO_KLOG("file", "findExecutable done name=%s result=none",
             nameStr.c_str());
    return succeed(Elm::alloc::nothing());
}

HPointer listBody(HPointer captured) {
    std::string pathStr = toString(Export::encode(captured));
    ECO_KLOG("file", "list start path=%s", pathStr.c_str());
    std::vector<std::string> entries;
    DIR* dir = opendir(pathStr.c_str());
    if (!dir) {
        int err = errno;
        ECO_KLOG("file", "list fail path=%s errno=%d msg=%s",
                 pathStr.c_str(), err, std::strerror(err));
        return failErrno(err, pathStr, "could not open directory");
    }
    struct dirent* entry;
    while ((entry = readdir(dir)) != nullptr) {
        std::string name = entry->d_name;
        if (name != "." && name != "..") {
            entries.push_back(name);
        }
    }
    closedir(dir);
    ECO_KLOG("file", "list done path=%s entries=%zu",
             pathStr.c_str(), entries.size());
    return succeedStringList(entries);
}

HPointer modificationTimeBody(HPointer captured) {
    std::string pathStr = toString(Export::encode(captured));
    ECO_KLOG("file", "modificationTime start path=%s", pathStr.c_str());
    struct stat st;
    if (stat(pathStr.c_str(), &st) != 0) {
        int err = errno;
        ECO_KLOG("file", "modificationTime fail path=%s errno=%d msg=%s",
                 pathStr.c_str(), err, std::strerror(err));
        return failErrno(err, pathStr, "could not stat file");
    }
#ifdef __APPLE__
    const struct timespec &mtim = st.st_mtimespec;
#else
    const struct timespec &mtim = st.st_mtim;
#endif
    int64_t millis = static_cast<int64_t>(mtim.tv_sec) * 1000 +
                     static_cast<int64_t>(mtim.tv_nsec) / 1000000;
    ECO_KLOG("file", "modificationTime done path=%s millis=%lld",
             pathStr.c_str(), (long long)millis);
    return succeedInt(millis);
}

HPointer getCwdBody(HPointer /*captured*/) {
    char buf[4096];
    if (getcwd(buf, sizeof(buf))) {
        ECO_KLOG("file", "getCwd done result=%s", buf);
        return succeedString(std::string(buf));
    }
    int err = errno;
    ECO_KLOG("file", "getCwd fail errno=%d msg=%s",
             err, std::strerror(err));
    return failErrno(err, "", "could not get current working directory");
}

HPointer setCwdBody(HPointer captured) {
    std::string pathStr = toString(Export::encode(captured));
    ECO_KLOG("file", "setCwd start path=%s", pathStr.c_str());
    if (chdir(pathStr.c_str()) != 0) {
        int err = errno;
        ECO_KLOG("file", "setCwd fail path=%s errno=%d msg=%s",
                 pathStr.c_str(), err, std::strerror(err));
        return failErrno(err, pathStr, "could not set working directory");
    }
    ECO_KLOG("file", "setCwd done path=%s", pathStr.c_str());
    return succeedUnit();
}

HPointer canonicalizeBody(HPointer captured) {
    std::string pathStr = toString(Export::encode(captured));
    ECO_KLOG("file", "canonicalize start path=%s", pathStr.c_str());
    char resolved[PATH_MAX];
    if (realpath(pathStr.c_str(), resolved)) {
        ECO_KLOG("file", "canonicalize done path=%s result=%s",
                 pathStr.c_str(), resolved);
        return succeedString(std::string(resolved));
    }
    // Fallback: resolve relative path without following symlinks.
    std::filesystem::path p = std::filesystem::absolute(pathStr);
    std::string result = p.lexically_normal().string();
    ECO_KLOG("file", "canonicalize fallback path=%s result=%s",
             pathStr.c_str(), result.c_str());
    return succeedString(result);
}

HPointer appDataDirBody(HPointer captured) {
    std::string nameStr = toString(Export::encode(captured));
    const char* home = std::getenv("HOME");
    if (!home) {
        ECO_KLOG("file", "appDataDir fail name=%s reason=no-HOME",
                 nameStr.c_str());
        return failString("HOME environment variable not set");
    }
    std::string dir;
#ifdef __APPLE__
    dir = std::string(home) + "/Library/Application Support/" + nameStr;
#else
    dir = std::string(home) + "/." + nameStr;
#endif
    ECO_KLOG("file", "appDataDir name=%s result=%s",
             nameStr.c_str(), dir.c_str());
    return succeedString(dir);
}

HPointer removeFileBody(HPointer captured) {
    std::string pathStr = toString(Export::encode(captured));
    ECO_KLOG("file", "removeFile start path=%s", pathStr.c_str());
    if (unlink(pathStr.c_str()) != 0) {
        int err = errno;
        ECO_KLOG("file", "removeFile fail path=%s errno=%d msg=%s",
                 pathStr.c_str(), err, std::strerror(err));
        return failErrno(err, pathStr, "could not remove file");
    }
    ECO_KLOG("file", "removeFile done path=%s", pathStr.c_str());
    return succeedUnit();
}

HPointer removeDirBody(HPointer captured) {
    std::string pathStr = toString(Export::encode(captured));
    ECO_KLOG("file", "removeDir start path=%s", pathStr.c_str());
    std::error_code ec;
    std::filesystem::remove_all(pathStr, ec);
    if (ec) {
        ECO_KLOG("file", "removeDir fail path=%s ec=%d msg=%s",
                 pathStr.c_str(), ec.value(), ec.message().c_str());
        return failErrno(ec.value(), pathStr, "could not remove directory: " + ec.message());
    }
    ECO_KLOG("file", "removeDir done path=%s", pathStr.c_str());
    return succeedUnit();
}

HPointer touchBody(HPointer captured) {
    std::string pathStr = toString(Export::encode(captured));
    ECO_KLOG("file", "touch start path=%s", pathStr.c_str());
    int fd = ::open(pathStr.c_str(), O_WRONLY | O_CREAT, 0644);
    if (fd >= 0) {
        ::close(fd);
    }
    if (utimensat(AT_FDCWD, pathStr.c_str(), nullptr, 0) != 0) {
        int err = errno;
        ECO_KLOG("file", "touch fail path=%s errno=%d msg=%s",
                 pathStr.c_str(), err, std::strerror(err));
        return failErrno(err, pathStr, "could not touch file");
    }
    ECO_KLOG("file", "touch done path=%s", pathStr.c_str());
    return succeedUnit();
}

// Stubs — TODO real impls. Wrapped in bindings for KERNEL_TASK_IO_001
// uniformity (so the deferred-binding surface is total).
HPointer lockBody(HPointer /*captured*/) { return succeedUnit(); }
HPointer unlockBody(HPointer /*captured*/) { return succeedUnit(); }

// --- 1-arg-Int bodies ---------------------------------------------------------

HPointer closeBody(HPointer captured) {
    Tuple2* tup = asTuple2(captured);
    int64_t fd = tup->a.i;
    ECO_KLOG("file", "close handle=%lld", (long long)fd);
    ::close(static_cast<int>(fd));
    return succeedUnit();
}

HPointer sizeBody(HPointer captured) {
    Tuple2* tup = asTuple2(captured);
    int64_t fd = tup->a.i;
    struct stat st;
    if (fstat(static_cast<int>(fd), &st) != 0) {
        int err = errno;
        ECO_KLOG("file", "size fail handle=%lld errno=%d msg=%s",
                 (long long)fd, err, std::strerror(err));
        return failErrno(err, "", "fstat failed");
    }
    ECO_KLOG("file", "size handle=%lld size=%lld",
             (long long)fd, (long long)st.st_size);
    return succeedInt(static_cast<int64_t>(st.st_size));
}

// --- 2-arg bodies -------------------------------------------------------------

HPointer writeStringBody(HPointer captured) {
    HPointer pathHP;
    HPointer contentHP;
    {
        Tuple2* tup = asTuple2(captured);
        pathHP = tup->a.p;
        contentHP = tup->b.p;
    }
    std::string pathStr = toString(Export::encode(pathHP));
    std::string data = toString(Export::encode(contentHP));
    ECO_KLOG("file", "writeString start path=%s size=%zu",
             pathStr.c_str(), data.size());
    std::ofstream file(pathStr);
    if (!file) {
        int err = errno;
        ECO_KLOG("file", "writeString fail path=%s errno=%d msg=%s",
                 pathStr.c_str(), err, std::strerror(err));
        return failErrno(err, pathStr, "could not open file for writing");
    }
    file << data;
    ECO_KLOG("file", "writeString done path=%s wrote=%zu",
             pathStr.c_str(), data.size());
    return succeedUnit();
}

HPointer writeBytesBody(HPointer captured) {
    HPointer pathHP;
    HPointer bytesHP;
    {
        Tuple2* tup = asTuple2(captured);
        pathHP = tup->a.p;
        bytesHP = tup->b.p;
    }
    std::string pathStr = toString(Export::encode(pathHP));
    void* ptr = Elm::Allocator::instance().resolve(bytesHP);
    size_t len = Elm::alloc::byteBufferLength(ptr);
    const uint8_t* data = Elm::alloc::byteBufferData(ptr);
    ECO_KLOG("file", "writeBytes start path=%s size=%zu",
             pathStr.c_str(), len);
    std::ofstream file(pathStr, std::ios::binary);
    if (!file) {
        int err = errno;
        ECO_KLOG("file", "writeBytes fail path=%s errno=%d msg=%s",
                 pathStr.c_str(), err, std::strerror(err));
        return failErrno(err, pathStr, "could not open file for writing");
    }
    file.write(reinterpret_cast<const char*>(data), len);
    ECO_KLOG("file", "writeBytes done path=%s wrote=%zu",
             pathStr.c_str(), len);
    return succeedUnit();
}

HPointer openBody(HPointer captured) {
    HPointer pathHP;
    int64_t modeVal;
    {
        Tuple2* tup = asTuple2(captured);
        pathHP = tup->a.p;
        modeVal = tup->b.i;
    }
    std::string pathStr = toString(Export::encode(pathHP));
    int flags;
    switch (modeVal) {
        case 0: flags = O_RDONLY; break;
        case 1: flags = O_WRONLY | O_CREAT | O_TRUNC; break;
        case 2: flags = O_WRONLY | O_CREAT | O_APPEND; break;
        case 3: flags = O_RDWR | O_CREAT; break;
        default: flags = O_RDONLY; break;
    }
    ECO_KLOG("file", "open start path=%s mode=%lld",
             pathStr.c_str(), (long long)modeVal);
    int fd = ::open(pathStr.c_str(), flags, 0644);
    if (fd < 0) {
        int err = errno;
        ECO_KLOG("file", "open fail path=%s errno=%d msg=%s",
                 pathStr.c_str(), err, std::strerror(err));
        return failErrno(err, pathStr, "could not open file");
    }
    ECO_KLOG("file", "open done path=%s handle=%d",
             pathStr.c_str(), fd);
    return succeedInt(fd);
}

HPointer hWriteStringBody(HPointer captured) {
    int64_t fd;
    HPointer contentHP;
    {
        Tuple2* tup = asTuple2(captured);
        fd = tup->a.i;
        contentHP = tup->b.p;
    }
    std::string data = toString(Export::encode(contentHP));
    ECO_KLOG("file", "hWriteString start handle=%lld size=%zu",
             (long long)fd, data.size());
    ssize_t written = ::write(static_cast<int>(fd), data.data(), data.size());
    if (written < 0) {
        int err = errno;
        ECO_KLOG("file", "hWriteString fail handle=%lld errno=%d msg=%s",
                 (long long)fd, err, std::strerror(err));
        return failErrno(err, "", "write to handle failed");
    }
    ECO_KLOG("file", "hWriteString done handle=%lld wrote=%zd",
             (long long)fd, written);
    return succeedUnit();
}

HPointer createDirBody(HPointer captured) {
    HPointer createParentsHP;
    HPointer pathHP;
    {
        Tuple2* tup = asTuple2(captured);
        createParentsHP = tup->a.p;
        pathHP = tup->b.p;
    }
    std::string pathStr = toString(Export::encode(pathHP));
    bool parents = Export::decodeBoxedBool(Export::encode(createParentsHP));
    ECO_KLOG("file", "createDir start path=%s parents=%d",
             pathStr.c_str(), (int)parents);
    std::error_code ec;
    if (parents) {
        std::filesystem::create_directories(pathStr, ec);
    } else {
        std::filesystem::create_directory(pathStr, ec);
    }
    if (ec) {
        ECO_KLOG("file", "createDir fail path=%s ec=%d msg=%s",
                 pathStr.c_str(), ec.value(), ec.message().c_str());
        return failErrno(ec.value(), pathStr, "could not create directory: " + ec.message());
    }
    ECO_KLOG("file", "createDir done path=%s", pathStr.c_str());
    return succeedUnit();
}

} // anonymous namespace

// ============================================================================
// Public API — thin binding-creation wrappers. The IO bodies live above.
// ============================================================================

uint64_t readString(uint64_t path) {
    return Export::encode(
        Eco::Kernel::makeBinding<readStringBody>(Export::decode(path)));
}

uint64_t writeString(uint64_t path, uint64_t content) {
    HPointer pathHP = Export::decode(path);
    HPointer contentHP = Export::decode(content);
    Elm::StackRootGuard g(&pathHP, &contentHP);
    HPointer payload = Elm::alloc::tuple2(
        Elm::alloc::boxed(pathHP), Elm::alloc::boxed(contentHP), 0);
    return Export::encode(Eco::Kernel::makeBinding<writeStringBody>(payload));
}

uint64_t readBytes(uint64_t path) {
    return Export::encode(
        Eco::Kernel::makeBinding<readBytesBody>(Export::decode(path)));
}

uint64_t writeBytes(uint64_t path, uint64_t bytes) {
    HPointer pathHP = Export::decode(path);
    HPointer bytesHP = Export::decode(bytes);
    Elm::StackRootGuard g(&pathHP, &bytesHP);
    HPointer payload = Elm::alloc::tuple2(
        Elm::alloc::boxed(pathHP), Elm::alloc::boxed(bytesHP), 0);
    return Export::encode(Eco::Kernel::makeBinding<writeBytesBody>(payload));
}

uint64_t open(uint64_t path, uint64_t mode) {
    HPointer pathHP = Export::decode(path);
    Elm::StackRootGuard g(&pathHP);
    // mode is an unboxed Int passed via the HPtr ABI (the MLIR generator
    // hands raw i64 bits even when the C++ signature is HPtr — matches the
    // pre-existing eager behavior of `int64_t modeVal = static_cast<int64_t>(mode)`).
    HPointer payload = Elm::alloc::tuple2(
        Elm::alloc::boxed(pathHP),
        Elm::alloc::unboxedInt(static_cast<int64_t>(mode)),
        /*mask: slot 1 unboxed Int (kind 01 << 2)=*/0x4);
    return Export::encode(Eco::Kernel::makeBinding<openBody>(payload));
}

uint64_t close(uint64_t handle) {
    HPointer payload = Elm::alloc::tuple2(
        Elm::alloc::unboxedInt(static_cast<int64_t>(handle)),
        Elm::alloc::boxed(Elm::alloc::unit()),
        0x1);
    return Export::encode(Eco::Kernel::makeBinding<closeBody>(payload));
}

uint64_t hWriteString(uint64_t handle, uint64_t content) {
    HPointer contentHP = Export::decode(content);
    Elm::StackRootGuard g(&contentHP);
    HPointer payload = Elm::alloc::tuple2(
        Elm::alloc::unboxedInt(static_cast<int64_t>(handle)),
        Elm::alloc::boxed(contentHP),
        0x1);
    return Export::encode(Eco::Kernel::makeBinding<hWriteStringBody>(payload));
}

uint64_t size(uint64_t handle) {
    HPointer payload = Elm::alloc::tuple2(
        Elm::alloc::unboxedInt(static_cast<int64_t>(handle)),
        Elm::alloc::boxed(Elm::alloc::unit()),
        0x1);
    return Export::encode(Eco::Kernel::makeBinding<sizeBody>(payload));
}

uint64_t lock(uint64_t path) {
    return Export::encode(
        Eco::Kernel::makeBinding<lockBody>(Export::decode(path)));
}

uint64_t unlock(uint64_t path) {
    return Export::encode(
        Eco::Kernel::makeBinding<unlockBody>(Export::decode(path)));
}

uint64_t fileExists(uint64_t path) {
    return Export::encode(
        Eco::Kernel::makeBinding<fileExistsBody>(Export::decode(path)));
}

uint64_t dirExists(uint64_t path) {
    return Export::encode(
        Eco::Kernel::makeBinding<dirExistsBody>(Export::decode(path)));
}

uint64_t findExecutable(uint64_t name) {
    return Export::encode(
        Eco::Kernel::makeBinding<findExecutableBody>(Export::decode(name)));
}

uint64_t list(uint64_t path) {
    return Export::encode(
        Eco::Kernel::makeBinding<listBody>(Export::decode(path)));
}

uint64_t modificationTime(uint64_t path) {
    return Export::encode(
        Eco::Kernel::makeBinding<modificationTimeBody>(Export::decode(path)));
}

uint64_t getCwd() {
    return Export::encode(
        Eco::Kernel::makeBinding<getCwdBody>(Elm::alloc::unit()));
}

uint64_t setCwd(uint64_t path) {
    return Export::encode(
        Eco::Kernel::makeBinding<setCwdBody>(Export::decode(path)));
}

uint64_t canonicalize(uint64_t path) {
    return Export::encode(
        Eco::Kernel::makeBinding<canonicalizeBody>(Export::decode(path)));
}

uint64_t appDataDir(uint64_t name) {
    return Export::encode(
        Eco::Kernel::makeBinding<appDataDirBody>(Export::decode(name)));
}

uint64_t createDir(uint64_t createParents, uint64_t path) {
    HPointer createParentsHP = Export::decode(createParents);
    HPointer pathHP = Export::decode(path);
    Elm::StackRootGuard g(&createParentsHP, &pathHP);
    HPointer payload = Elm::alloc::tuple2(
        Elm::alloc::boxed(createParentsHP), Elm::alloc::boxed(pathHP), 0);
    return Export::encode(Eco::Kernel::makeBinding<createDirBody>(payload));
}

uint64_t removeFile(uint64_t path) {
    return Export::encode(
        Eco::Kernel::makeBinding<removeFileBody>(Export::decode(path)));
}

uint64_t removeDir(uint64_t path) {
    return Export::encode(
        Eco::Kernel::makeBinding<removeDirBody>(Export::decode(path)));
}

uint64_t touch(uint64_t path) {
    return Export::encode(
        Eco::Kernel::makeBinding<touchBody>(Export::decode(path)));
}

} // namespace Eco::Kernel::File
