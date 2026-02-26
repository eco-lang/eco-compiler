//===- FileExports.cpp - C-linkage exports for File module ----------------===//

#include "KernelExports.h"
#include "File.hpp"

using namespace Eco::Kernel;

uint64_t Eco_Kernel_File_readString(uint64_t path) {
    return File::readString(path);
}

uint64_t Eco_Kernel_File_writeString(uint64_t path, uint64_t content) {
    return File::writeString(path, content);
}

uint64_t Eco_Kernel_File_readBytes(uint64_t path) {
    return File::readBytes(path);
}

uint64_t Eco_Kernel_File_writeBytes(uint64_t path, uint64_t bytes) {
    return File::writeBytes(path, bytes);
}

uint64_t Eco_Kernel_File_open(uint64_t path, uint64_t mode) {
    return File::open(path, mode);
}

uint64_t Eco_Kernel_File_close(uint64_t handle) {
    return File::close(handle);
}

int64_t Eco_Kernel_File_size(uint64_t handle) {
    return File::size(handle);
}

uint64_t Eco_Kernel_File_lock(uint64_t path) {
    return File::lock(path);
}

uint64_t Eco_Kernel_File_unlock(uint64_t path) {
    return File::unlock(path);
}

uint64_t Eco_Kernel_File_fileExists(uint64_t path) {
    return File::fileExists(path);
}

uint64_t Eco_Kernel_File_dirExists(uint64_t path) {
    return File::dirExists(path);
}

uint64_t Eco_Kernel_File_findExecutable(uint64_t name) {
    return File::findExecutable(name);
}

uint64_t Eco_Kernel_File_list(uint64_t path) {
    return File::list(path);
}

int64_t Eco_Kernel_File_modificationTime(uint64_t path) {
    return File::modificationTime(path);
}

uint64_t Eco_Kernel_File_getCwd() {
    return File::getCwd();
}

uint64_t Eco_Kernel_File_setCwd(uint64_t path) {
    return File::setCwd(path);
}

uint64_t Eco_Kernel_File_canonicalize(uint64_t path) {
    return File::canonicalize(path);
}

uint64_t Eco_Kernel_File_appDataDir(uint64_t name) {
    return File::appDataDir(name);
}

uint64_t Eco_Kernel_File_createDir(uint64_t createParents, uint64_t path) {
    return File::createDir(createParents, path);
}

uint64_t Eco_Kernel_File_removeFile(uint64_t path) {
    return File::removeFile(path);
}

uint64_t Eco_Kernel_File_removeDir(uint64_t path) {
    return File::removeDir(path);
}
