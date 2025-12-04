#include "File.hpp"
#include <stdexcept>

namespace Elm::Kernel::File {

std::u16string name(File* file) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.File.name not implemented");
}

std::u16string mime(File* file) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.File.mime not implemented");
}

int64_t size(File* file) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.File.size not implemented");
}

int64_t lastModified(File* file) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.File.lastModified not implemented");
}

Task* toString(File* file) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.File.toString not implemented");
}

Task* toBytes(File* file) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.File.toBytes not implemented");
}

Task* toUrl(File* file) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.File.toUrl not implemented");
}

Task* uploadOne(const std::u16string& mimeTypes) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.File.uploadOne not implemented");
}

Task* uploadOneOrMore(const std::u16string& mimeTypes) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.File.uploadOneOrMore not implemented");
}

Task* download(const std::u16string& name, const std::u16string& mime, const std::u16string& content) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.File.download not implemented");
}

Task* downloadUrl(const std::u16string& name, const std::u16string& url) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.File.downloadUrl not implemented");
}

Decoder* decoder() {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.File.decoder not implemented");
}

Bytes* makeBytesSafeForInternetExplorer(Bytes* bytes) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.File.makeBytesSafeForInternetExplorer not implemented");
}

} // namespace Elm::Kernel::File
