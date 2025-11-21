#include "../runtime/include/object_pool.hpp"
#include <iostream>

using namespace Elm;

struct TestObject {
    int value;
    TestObject() : value(0) {}
};

TestObject* createTestObject() {
    return new TestObject();
}

int main() {
    std::cout << "Creating pool...\n";

    ObjectPoolManager<TestObject> pool(createTestObject, 64);

    std::cout << "Allocating object...\n";
    TestObject* obj = pool.getLocalPool()->allocate();

    std::cout << "Object allocated: " << obj << "\n";
    obj->value = 42;

    std::cout << "Freeing object...\n";
    pool.getLocalPool()->free(obj);

    std::cout << "Object freed\n";

    std::cout << "Done!\n";
    return 0;
}
