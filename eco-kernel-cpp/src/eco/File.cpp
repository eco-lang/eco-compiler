//===- File.cpp - File kernel module implementation -----------------------===//

#include "File.hpp"
#include "KernelHelpers.hpp"
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

uint64_t readString(uint64_t path) {
    std::string pathStr = toString(path);
    std::ifstream file(pathStr);
    if (!file) {
        return taskFailString("File not found: " + pathStr);
    }
    std::ostringstream ss;
    ss << file.rdbuf();
    return taskSucceedString(ss.str());
}

uint64_t writeString(uint64_t path, uint64_t content) {
    std::string pathStr = toString(path);
    std::string data = toString(content);
    std::ofstream file(pathStr);
    if (!file) {
        return taskFailString("Cannot write file: " + pathStr);
    }
    file << data;
    return taskSucceedUnit();
}

uint64_t readBytes(uint64_t path) {
    std::string pathStr = toString(path);
    std::ifstream file(pathStr, std::ios::binary | std::ios::ate);
    if (!file) {
        return taskFailString("File not found: " + pathStr);
    }
    auto size = file.tellg();
    file.seekg(0, std::ios::beg);
    std::vector<uint8_t> buffer(static_cast<size_t>(size));
    file.read(reinterpret_cast<char*>(buffer.data()), size);
    HPointer bytes = Elm::alloc::allocByteBuffer(buffer.data(), buffer.size());
    return taskSucceed(bytes);
}

uint64_t writeBytes(uint64_t path, uint64_t bytes) {
    std::string pathStr = toString(path);
    HPointer h = Export::decode(bytes);
    void* ptr = Elm::Allocator::instance().resolve(h);
    size_t len = Elm::alloc::byteBufferLength(ptr);
    const uint8_t* data = Elm::alloc::byteBufferData(ptr);
    std::ofstream file(pathStr, std::ios::binary);
    if (!file) {
        return taskFailString("Cannot write file: " + pathStr);
    }
    file.write(reinterpret_cast<const char*>(data), len);
    return taskSucceedUnit();
}

uint64_t open(uint64_t path, uint64_t mode) {
    std::string pathStr = toString(path);
    // mode is an unboxed int passed directly as uint64_t
    int64_t modeVal = static_cast<int64_t>(mode);
    int flags;
    switch (modeVal) {
        case 0: flags = O_RDONLY; break;
        case 1: flags = O_WRONLY | O_CREAT | O_TRUNC; break;
        case 2: flags = O_WRONLY | O_CREAT | O_APPEND; break;
        case 3: flags = O_RDWR | O_CREAT; break;
        default: flags = O_RDONLY; break;
    }
    int fd = ::open(pathStr.c_str(), flags, 0644);
    if (fd < 0) {
        return taskFailString("Cannot open file: " + pathStr);
    }
    return taskSucceedInt(fd);
}

uint64_t close(uint64_t handle) {
    int64_t fd = static_cast<int64_t>(handle);
    ::close(static_cast<int>(fd));
    return taskSucceedUnit();
}

uint64_t hWriteString(uint64_t handle, uint64_t content) {
    int64_t fd = static_cast<int64_t>(handle);
    std::string data = toString(content);
    ssize_t written = ::write(static_cast<int>(fd), data.data(), data.size());
    if (written < 0) {
        return taskFailString("Write to handle failed");
    }
    return taskSucceedUnit();
}

int64_t size(uint64_t handle) {
    int64_t fd = static_cast<int64_t>(handle);
    struct stat st;
    if (fstat(static_cast<int>(fd), &st) != 0) {
        return 0;
    }
    return static_cast<int64_t>(st.st_size);
}

uint64_t lock(uint64_t /*path*/) {
    // TODO: implement file locking
    return taskSucceedUnit();
}

uint64_t unlock(uint64_t /*path*/) {
    // TODO: implement file unlocking
    return taskSucceedUnit();
}

uint64_t fileExists(uint64_t path) {
    std::string pathStr = toString(path);
    struct stat st;
    bool exists = (stat(pathStr.c_str(), &st) == 0 && S_ISREG(st.st_mode));
    return taskSucceedBool(exists);
}

uint64_t dirExists(uint64_t path) {
    std::string pathStr = toString(path);
    struct stat st;
    bool exists = (stat(pathStr.c_str(), &st) == 0 && S_ISDIR(st.st_mode));
    return taskSucceedBool(exists);
}

uint64_t findExecutable(uint64_t name) {
    std::string nameStr = toString(name);
    const char* pathEnv = std::getenv("PATH");
    if (!pathEnv) {
        return taskSucceed(Elm::alloc::nothing());
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
            HPointer str = Elm::alloc::allocStringFromUTF8(fullPath);
            return taskSucceed(Elm::alloc::just(Elm::alloc::boxed(str), true));
        }
        pos = sep + 1;
    }
    return taskSucceed(Elm::alloc::nothing());
}

uint64_t list(uint64_t path) {
    std::string pathStr = toString(path);
    std::vector<std::string> entries;
    DIR* dir = opendir(pathStr.c_str());
    if (!dir) {
        return taskFailString("Cannot list directory: " + pathStr);
    }
    struct dirent* entry;
    while ((entry = readdir(dir)) != nullptr) {
        std::string name = entry->d_name;
        if (name != "." && name != "..") {
            entries.push_back(name);
        }
    }
    closedir(dir);
    return taskSucceedStringList(entries);
}

int64_t modificationTime(uint64_t path) {
    std::string pathStr = toString(path);
    struct stat st;
    if (stat(pathStr.c_str(), &st) != 0) {
        return 0;
    }
    // Convert to milliseconds since epoch.
    return static_cast<int64_t>(st.st_mtim.tv_sec) * 1000 +
           static_cast<int64_t>(st.st_mtim.tv_nsec) / 1000000;
}

uint64_t getCwd() {
    char buf[4096];
    if (getcwd(buf, sizeof(buf))) {
        return taskSucceedString(std::string(buf));
    }
    return taskFailString("Cannot get current working directory");
}

uint64_t setCwd(uint64_t path) {
    std::string pathStr = toString(path);
    if (chdir(pathStr.c_str()) != 0) {
        return taskFailString("Cannot set working directory: " + pathStr);
    }
    return taskSucceedUnit();
}

uint64_t canonicalize(uint64_t path) {
    std::string pathStr = toString(path);
    char resolved[PATH_MAX];
    if (realpath(pathStr.c_str(), resolved)) {
        return taskSucceedString(std::string(resolved));
    }
    // Fallback: resolve relative path without following symlinks.
    std::filesystem::path p = std::filesystem::absolute(pathStr);
    return taskSucceedString(p.lexically_normal().string());
}

uint64_t appDataDir(uint64_t name) {
    std::string nameStr = toString(name);
    const char* home = std::getenv("HOME");
    if (!home) {
        return taskFailString("HOME environment variable not set");
    }
    std::string dir;
#ifdef __APPLE__
    dir = std::string(home) + "/Library/Application Support/" + nameStr;
#else
    dir = std::string(home) + "/." + nameStr;
#endif
    return taskSucceedString(dir);
}

uint64_t createDir(uint64_t createParents, uint64_t path) {
    std::string pathStr = toString(path);
    bool parents = Export::decodeBoxedBool(createParents);
    std::error_code ec;
    if (parents) {
        std::filesystem::create_directories(pathStr, ec);
    } else {
        std::filesystem::create_directory(pathStr, ec);
    }
    if (ec) {
        return taskFailString("Cannot create directory: " + pathStr + " (" + ec.message() + ")");
    }
    return taskSucceedUnit();
}

uint64_t removeFile(uint64_t path) {
    std::string pathStr = toString(path);
    if (unlink(pathStr.c_str()) != 0) {
        return taskFailString("Cannot remove file: " + pathStr);
    }
    return taskSucceedUnit();
}

uint64_t removeDir(uint64_t path) {
    std::string pathStr = toString(path);
    std::error_code ec;
    std::filesystem::remove_all(pathStr, ec);
    if (ec) {
        return taskFailString("Cannot remove directory: " + pathStr + " (" + ec.message() + ")");
    }
    return taskSucceedUnit();
}

} // namespace Eco::Kernel::File
