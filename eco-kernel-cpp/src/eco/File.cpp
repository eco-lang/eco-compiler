//===- File.cpp - Stub implementations for File kernel module -------------===//

#include "File.hpp"

namespace Eco::Kernel::File {

uint64_t readString(uint64_t /*path*/) {
    // TODO: read file at path as UTF-8, return Elm String
    return 0;
}

uint64_t writeString(uint64_t /*path*/, uint64_t /*content*/) {
    // TODO: write UTF-8 string to file at path, return Unit
    return 0;
}

uint64_t readBytes(uint64_t /*path*/) {
    // TODO: read file at path as raw bytes, return Elm Bytes
    return 0;
}

uint64_t writeBytes(uint64_t /*path*/, uint64_t /*bytes*/) {
    // TODO: write raw bytes to file at path, return Unit
    return 0;
}

uint64_t open(uint64_t /*path*/, uint64_t /*mode*/) {
    // TODO: open file handle with IOMode, return Handle
    return 0;
}

uint64_t close(uint64_t /*handle*/) {
    // TODO: close file handle, return Unit
    return 0;
}

int64_t size(uint64_t /*handle*/) {
    // TODO: get file size via handle, return Int
    return 0;
}

uint64_t lock(uint64_t /*path*/) {
    // TODO: acquire file lock (blocks until acquired), return Unit
    return 0;
}

uint64_t unlock(uint64_t /*path*/) {
    // TODO: release file lock, return Unit
    return 0;
}

uint64_t fileExists(uint64_t /*path*/) {
    // TODO: check if file exists, return boxed Bool
    return 0;
}

uint64_t dirExists(uint64_t /*path*/) {
    // TODO: check if directory exists, return boxed Bool
    return 0;
}

uint64_t findExecutable(uint64_t /*name*/) {
    // TODO: find executable on PATH, return Maybe String
    return 0;
}

uint64_t list(uint64_t /*path*/) {
    // TODO: list directory contents, return List String
    return 0;
}

int64_t modificationTime(uint64_t /*path*/) {
    // TODO: get file modification time, return Int (ms since epoch)
    return 0;
}

uint64_t getCwd() {
    // TODO: get current working directory, return String
    return 0;
}

uint64_t setCwd(uint64_t /*path*/) {
    // TODO: set current working directory, return Unit
    return 0;
}

uint64_t canonicalize(uint64_t /*path*/) {
    // TODO: resolve symlinks and normalize, return String
    return 0;
}

uint64_t appDataDir(uint64_t /*name*/) {
    // TODO: get app-specific user data dir, return String
    return 0;
}

uint64_t createDir(uint64_t /*createParents*/, uint64_t /*path*/) {
    // TODO: create directory, optionally with parents, return Unit
    return 0;
}

uint64_t removeFile(uint64_t /*path*/) {
    // TODO: remove a file, return Unit
    return 0;
}

uint64_t removeDir(uint64_t /*path*/) {
    // TODO: remove a directory tree, return Unit
    return 0;
}

} // namespace Eco::Kernel::File
