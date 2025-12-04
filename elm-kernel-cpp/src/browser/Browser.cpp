#include "Browser.hpp"
#include <stdexcept>

namespace Elm::Kernel::Browser {

Value* element(Value* impl) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Browser.element not implemented");
}

Value* document(Value* impl) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Browser.document not implemented");
}

Value* application(Value* impl) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Browser.application not implemented");
}

Task* load(const std::u16string& url) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Browser.load not implemented");
}

Task* reload(bool skipCache) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Browser.reload not implemented");
}

Task* pushUrl(Value* key, const std::u16string& url) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Browser.pushUrl not implemented");
}

Task* replaceUrl(Value* key, const std::u16string& url) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Browser.replaceUrl not implemented");
}

Task* go(Value* key, int steps) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Browser.go not implemented");
}

Task* getViewport() {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Browser.getViewport not implemented");
}

Task* getViewportOf(const std::u16string& id) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Browser.getViewportOf not implemented");
}

Task* setViewport(double x, double y) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Browser.setViewport not implemented");
}

Task* setViewportOf(const std::u16string& id, double x, double y) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Browser.setViewportOf not implemented");
}

Task* getElement(const std::u16string& id) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Browser.getElement not implemented");
}

Task* now() {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Browser.now not implemented");
}

Task* rAF() {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Browser.rAF not implemented");
}

Value* on(Value* node, const std::u16string& eventName, Value* handler) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Browser.on not implemented");
}

Value* decodeEvent(Decoder* decoder) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Browser.decodeEvent not implemented");
}

Value* doc() {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Browser.doc not implemented");
}

Value* window() {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Browser.window not implemented");
}

Value* withWindow(std::function<Value*(Value*)> func) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Browser.withWindow not implemented");
}

Value* visibilityInfo() {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Browser.visibilityInfo not implemented");
}

Value* call(Value* func) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.Browser.call not implemented");
}

} // namespace Elm::Kernel::Browser
