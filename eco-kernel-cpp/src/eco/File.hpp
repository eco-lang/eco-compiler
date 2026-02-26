#ifndef ECO_FILE_HPP
#define ECO_FILE_HPP

#include <cstdint>

namespace Eco::Kernel::File {

uint64_t readString(uint64_t path);
uint64_t writeString(uint64_t path, uint64_t content);
uint64_t readBytes(uint64_t path);
uint64_t writeBytes(uint64_t path, uint64_t bytes);
uint64_t open(uint64_t path, uint64_t mode);
uint64_t close(uint64_t handle);
int64_t size(uint64_t handle);
uint64_t lock(uint64_t path);
uint64_t unlock(uint64_t path);
uint64_t fileExists(uint64_t path);
uint64_t dirExists(uint64_t path);
uint64_t findExecutable(uint64_t name);
uint64_t list(uint64_t path);
int64_t modificationTime(uint64_t path);
uint64_t getCwd();
uint64_t setCwd(uint64_t path);
uint64_t canonicalize(uint64_t path);
uint64_t appDataDir(uint64_t name);
uint64_t createDir(uint64_t createParents, uint64_t path);
uint64_t removeFile(uint64_t path);
uint64_t removeDir(uint64_t path);

} // namespace Eco::Kernel::File

#endif // ECO_FILE_HPP
