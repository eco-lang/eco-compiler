//===- FileExports.cpp - C-linkage exports for File module ----------------===//

#include "KernelExports.h"
#include "File.hpp"

using namespace Eco::Kernel;
using Elm::HPtr;

HPtr Eco_Kernel_File_readString(HPtr path) {
    return HPtr::fromBits(File::readString(path.toBits()));
}

HPtr Eco_Kernel_File_writeString(HPtr path, HPtr content) {
    return HPtr::fromBits(File::writeString(path.toBits(), content.toBits()));
}

HPtr Eco_Kernel_File_readBytes(HPtr path) {
    return HPtr::fromBits(File::readBytes(path.toBits()));
}

HPtr Eco_Kernel_File_writeBytes(HPtr path, HPtr bytes) {
    return HPtr::fromBits(File::writeBytes(path.toBits(), bytes.toBits()));
}

HPtr Eco_Kernel_File_open(HPtr path, HPtr mode) {
    return HPtr::fromBits(File::open(path.toBits(), mode.toBits()));
}

HPtr Eco_Kernel_File_close(HPtr handle) {
    return HPtr::fromBits(File::close(handle.toBits()));
}

uint64_t Eco_Kernel_File_size(HPtr handle) {
    return File::size(handle.toBits());
}

HPtr Eco_Kernel_File_lock(HPtr path) {
    return HPtr::fromBits(File::lock(path.toBits()));
}

HPtr Eco_Kernel_File_unlock(HPtr path) {
    return HPtr::fromBits(File::unlock(path.toBits()));
}

HPtr Eco_Kernel_File_fileExists(HPtr path) {
    return HPtr::fromBits(File::fileExists(path.toBits()));
}

HPtr Eco_Kernel_File_dirExists(HPtr path) {
    return HPtr::fromBits(File::dirExists(path.toBits()));
}

HPtr Eco_Kernel_File_findExecutable(HPtr name) {
    return HPtr::fromBits(File::findExecutable(name.toBits()));
}

HPtr Eco_Kernel_File_list(HPtr path) {
    return HPtr::fromBits(File::list(path.toBits()));
}

uint64_t Eco_Kernel_File_modificationTime(HPtr path) {
    return File::modificationTime(path.toBits());
}

HPtr Eco_Kernel_File_getCwd() {
    return HPtr::fromBits(File::getCwd());
}

HPtr Eco_Kernel_File_setCwd(HPtr path) {
    return HPtr::fromBits(File::setCwd(path.toBits()));
}

HPtr Eco_Kernel_File_canonicalize(HPtr path) {
    return HPtr::fromBits(File::canonicalize(path.toBits()));
}

HPtr Eco_Kernel_File_appDataDir(HPtr name) {
    return HPtr::fromBits(File::appDataDir(name.toBits()));
}

HPtr Eco_Kernel_File_createDir(HPtr createParents, HPtr path) {
    return HPtr::fromBits(File::createDir(createParents.toBits(), path.toBits()));
}

HPtr Eco_Kernel_File_removeFile(HPtr path) {
    return HPtr::fromBits(File::removeFile(path.toBits()));
}

HPtr Eco_Kernel_File_removeDir(HPtr path) {
    return HPtr::fromBits(File::removeDir(path.toBits()));
}

HPtr Eco_Kernel_File_hWriteString(HPtr handle, HPtr content) {
    return HPtr::fromBits(File::hWriteString(handle.toBits(), content.toBits()));
}

HPtr Eco_Kernel_File_touch(HPtr path) {
    return HPtr::fromBits(File::touch(path.toBits()));
}
