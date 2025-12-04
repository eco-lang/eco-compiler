#include "Http.hpp"
#include <stdexcept>

namespace Elm::Kernel::Http {

Body* emptyBody() {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Http.emptyBody not implemented");
}

Value* pair(const std::u16string& key, const std::u16string& value) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Http.pair not implemented");
}

Value* bytesToBlob(Bytes* bytes, const std::u16string& mimeType) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Http.bytesToBlob not implemented");
}

Value* toDataView(Bytes* bytes) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Http.toDataView not implemented");
}

Value* toFormData(Value* parts) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Http.toFormData not implemented");
}

Expect* expect(const std::u16string& responseType, std::function<Value*(Value*)> toValue) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Http.expect not implemented");
}

Expect* mapExpect(std::function<Value*(Value*)> func, Expect* expect) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Http.mapExpect not implemented");
}

Task* toTask(Value* request) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Http.toTask not implemented");
}

} // namespace Elm::Kernel::Http
