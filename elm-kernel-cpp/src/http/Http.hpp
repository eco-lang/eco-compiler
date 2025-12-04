#ifndef ELM_KERNEL_HTTP_HPP
#define ELM_KERNEL_HTTP_HPP

#include <string>
#include <functional>

namespace Elm::Kernel::Http {

// Forward declarations
struct Value;
struct Task;
struct Body;
struct Expect;
struct Bytes;

// Create empty body
Body* emptyBody();

// Create a key-value pair for headers/params
Value* pair(const std::u16string& key, const std::u16string& value);

// Convert bytes to blob
Value* bytesToBlob(Bytes* bytes, const std::u16string& mimeType);

// Convert to DataView
Value* toDataView(Bytes* bytes);

// Convert to FormData
Value* toFormData(Value* parts);

// Create an expectation for response handling
Expect* expect(const std::u16string& responseType, std::function<Value*(Value*)> toValue);

// Map over an expectation
Expect* mapExpect(std::function<Value*(Value*)> func, Expect* expect);

// Convert HTTP request to Task
Task* toTask(Value* request);

} // namespace Elm::Kernel::Http

#endif // ELM_KERNEL_HTTP_HPP
