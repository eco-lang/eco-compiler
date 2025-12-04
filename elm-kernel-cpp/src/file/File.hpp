#ifndef ELM_KERNEL_FILE_HPP
#define ELM_KERNEL_FILE_HPP

#include <string>
#include <cstdint>

namespace Elm::Kernel::File {

// Forward declarations
struct Value;
struct Task;
struct File;
struct Bytes;
struct Decoder;

// File properties
std::u16string name(File* file);
std::u16string mime(File* file);
int64_t size(File* file);
int64_t lastModified(File* file);

// File reading
Task* toString(File* file);
Task* toBytes(File* file);
Task* toUrl(File* file);

// File selection
Task* uploadOne(const std::u16string& mimeTypes);
Task* uploadOneOrMore(const std::u16string& mimeTypes);

// File downloading
Task* download(const std::u16string& name, const std::u16string& mime, const std::u16string& content);
Task* downloadUrl(const std::u16string& name, const std::u16string& url);

// JSON decoder for File objects
Decoder* decoder();

// IE compatibility helper
Bytes* makeBytesSafeForInternetExplorer(Bytes* bytes);

} // namespace Elm::Kernel::File

#endif // ELM_KERNEL_FILE_HPP
