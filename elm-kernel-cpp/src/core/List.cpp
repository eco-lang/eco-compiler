#include "List.hpp"
#include <stdexcept>

namespace Elm::Kernel::List {

List* cons(Value* head, List* tail) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.List.cons not implemented");
}

List* fromArray(Array* array) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.List.fromArray not implemented");
}

Array* toArray(List* list) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.List.toArray not implemented");
}

List* map2(std::function<Value*(Value*, Value*)> func, List* xs, List* ys) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.List.map2 not implemented");
}

List* map3(std::function<Value*(Value*, Value*, Value*)> func, List* xs, List* ys, List* zs) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.List.map3 not implemented");
}

List* map4(std::function<Value*(Value*, Value*, Value*, Value*)> func, List* ws, List* xs, List* ys, List* zs) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.List.map4 not implemented");
}

List* map5(std::function<Value*(Value*, Value*, Value*, Value*, Value*)> func, List* vs, List* ws, List* xs, List* ys, List* zs) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.List.map5 not implemented");
}

List* sortBy(std::function<Value*(Value*)> func, List* list) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.List.sortBy not implemented");
}

List* sortWith(std::function<int(Value*, Value*)> func, List* list) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.List.sortWith not implemented");
}

} // namespace Elm::Kernel::List
