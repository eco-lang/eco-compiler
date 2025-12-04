#ifndef ELM_KERNEL_BROWSER_HPP
#define ELM_KERNEL_BROWSER_HPP

#include <string>
#include <functional>

namespace Elm::Kernel::Browser {

// Forward declarations
struct Value;
struct Task;
struct Decoder;

// Program types
Value* element(Value* impl);
Value* document(Value* impl);
Value* application(Value* impl);

// Navigation
Task* load(const std::u16string& url);
Task* reload(bool skipCache);
Task* pushUrl(Value* key, const std::u16string& url);
Task* replaceUrl(Value* key, const std::u16string& url);
Task* go(Value* key, int steps);

// Viewport
Task* getViewport();
Task* getViewportOf(const std::u16string& id);
Task* setViewport(double x, double y);
Task* setViewportOf(const std::u16string& id, double x, double y);

// Element queries
Task* getElement(const std::u16string& id);

// Time
Task* now();

// Animation
Task* rAF();

// Events
Value* on(Value* node, const std::u16string& eventName, Value* handler);
Value* decodeEvent(Decoder* decoder);

// Document access
Value* doc();

// Window access
Value* window();
Value* withWindow(std::function<Value*(Value*)> func);

// Visibility
Value* visibilityInfo();

// Internal helpers
Value* call(Value* func);

} // namespace Elm::Kernel::Browser

#endif // ELM_KERNEL_BROWSER_HPP
