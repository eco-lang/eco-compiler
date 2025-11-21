#include "../runtime/include/object_pool.hpp"
#include <iostream>
#include <thread>
#include <vector>
#include <cassert>
#include <atomic>

using namespace Elm;

// Simple test object
struct TestObject {
    int value;

    TestObject() : value(0) {}
    explicit TestObject(int v) : value(v) {}
};

// Counter for tracking object creation (non-atomic for single-threaded tests)
static int objectsCreated = 0;

// Factory function for test objects
TestObject* createTestObject() {
    objectsCreated++;
    return new TestObject(objectsCreated);
}

// Atomic counter for multi-threaded tests
std::atomic<int> objectsCreatedMT{0};

// Factory function for multi-threaded tests
TestObject* createTestObjectMT() {
    objectsCreatedMT++;
    return new TestObject(objectsCreatedMT.load());
}

// Test 1: Basic allocation and freeing
void test_basic_alloc_free() {
    std::cout << "Test 1: Basic allocation and freeing... ";

    objectsCreated = 0;
    ObjectPoolManager<TestObject> pool(createTestObject, 64);

    // Allocate one object
    TestObject* obj = pool.getLocalPool()->allocate();
    assert(obj != nullptr);
    assert(obj->value > 0); // Created by factory

    // Modify it
    obj->value = 999;

    // Free it
    pool.getLocalPool()->free(obj);

    // Allocate again - should get same object back
    TestObject* obj2 = pool.getLocalPool()->allocate();
    assert(obj2 == obj);
    assert(obj2->value == 999); // Object not zeroed

    pool.getLocalPool()->free(obj2);

    std::cout << "PASS\n";
}

// Test 2: Bin overflow - allocate more than bin size
void test_bin_overflow() {
    std::cout << "Test 2: Bin overflow... ";

    objectsCreated = 0;
    ObjectPoolManager<TestObject> pool(createTestObject, 64);

    std::vector<TestObject*> objects;

    // Allocate 200 objects (more than one bin)
    for (int i = 0; i < 200; ++i) {
        TestObject* obj = pool.getLocalPool()->allocate();
        assert(obj != nullptr);
        objects.push_back(obj);
    }

    // Should have created at least 200 objects
    assert(objectsCreated >= 200);

    // Free all
    for (auto* obj : objects) {
        pool.getLocalPool()->free(obj);
    }

    std::cout << "PASS\n";
}

// Test 3: Bin underflow - free more than bin size
void test_bin_underflow() {
    std::cout << "Test 3: Bin underflow... ";

    objectsCreated = 0;
    ObjectPoolManager<TestObject> pool(createTestObject, 64);

    std::vector<TestObject*> objects;

    // Allocate 100 objects
    for (int i = 0; i < 100; ++i) {
        objects.push_back(pool.getLocalPool()->allocate());
    }

    // Free all (will overflow empty bin cache)
    for (auto* obj : objects) {
        pool.getLocalPool()->free(obj);
    }

    // Allocate again - should reuse some
    TestObject* obj = pool.getLocalPool()->allocate();
    assert(obj != nullptr);
    pool.getLocalPool()->free(obj);

    std::cout << "PASS\n";
}

// Test 4: Thread-local caching
void test_thread_local_caching() {
    std::cout << "Test 4: Thread-local caching... ";

    objectsCreated = 0;
    // Smaller initial bins to test reuse better
    ObjectPoolManager<TestObject> pool(createTestObject,
                                       64,  // bin size
                                       2,   // initial full bins
                                       2);  // initial empty bins

    // Allocate and free in a loop - should reuse bins
    for (int round = 0; round < 5; ++round) {
        std::vector<TestObject*> objects;

        // Allocate 50 objects
        for (int i = 0; i < 50; ++i) {
            objects.push_back(pool.getLocalPool()->allocate());
        }

        // Free all
        for (auto* obj : objects) {
            pool.getLocalPool()->free(obj);
        }
    }

    // Initial bins: 2 * 64 = 128 objects
    // Should not need to create many more due to reuse
    assert(objectsCreated < 200);

    std::cout << "PASS (created " << objectsCreated << " objects)\n";
}

// Test 5: Object reuse
void test_object_reuse() {
    std::cout << "Test 5: Object reuse... ";

    objectsCreated = 0;
    ObjectPoolManager<TestObject> pool(createTestObject, 64);

    // Allocate 10 objects and remember their addresses
    std::vector<TestObject*> objects;
    for (int i = 0; i < 10; ++i) {
        TestObject* obj = pool.getLocalPool()->allocate();
        obj->value = i * 100;
        objects.push_back(obj);
    }

    int initialCreated = objectsCreated;

    // Free all
    for (auto* obj : objects) {
        pool.getLocalPool()->free(obj);
    }

    // Allocate again - should reuse without creating new
    std::vector<TestObject*> objects2;
    for (int i = 0; i < 10; ++i) {
        objects2.push_back(pool.getLocalPool()->allocate());
    }

    // Should not have created new objects
    assert(objectsCreated == initialCreated);

    // Should have gotten same objects back (order may differ)
    for (auto* obj : objects2) {
        pool.getLocalPool()->free(obj);
    }

    std::cout << "PASS\n";
}

// Test 6: Multi-threaded allocation
void test_multithreaded() {
    std::cout << "Test 6: Multi-threaded allocation... ";

    objectsCreatedMT = 0;
    ObjectPoolManager<TestObject> pool(createTestObjectMT, 64);

    const int numThreads = 4;
    const int allocsPerThread = 100;

    std::vector<std::thread> threads;

    for (int t = 0; t < numThreads; ++t) {
        threads.emplace_back([&pool, allocsPerThread]() {
            std::vector<TestObject*> objects;

            // Allocate
            for (int i = 0; i < allocsPerThread; ++i) {
                TestObject* obj = pool.getLocalPool()->allocate();
                assert(obj != nullptr);
                obj->value = i;
                objects.push_back(obj);
            }

            // Free
            for (auto* obj : objects) {
                pool.getLocalPool()->free(obj);
            }
        });
    }

    for (auto& thread : threads) {
        thread.join();
    }

    std::cout << "PASS (created " << objectsCreatedMT.load() << " objects across "
              << numThreads << " threads)\n";
}

// Test 7: Gatherer bin (partial bins on thread exit)
void test_gatherer_bin() {
    std::cout << "Test 7: Gatherer bin... ";

    objectsCreated = 0;
    ObjectPoolManager<TestObject> pool(createTestObject, 64);

    // Thread that allocates a partial bin and exits
    std::thread t([&pool]() {
        std::vector<TestObject*> objects;

        // Allocate 30 objects (less than bin size of 64)
        for (int i = 0; i < 30; ++i) {
            objects.push_back(pool.getLocalPool()->allocate());
        }

        // Free 20 of them (leaving 10 in current bin)
        for (int i = 0; i < 20; ++i) {
            pool.getLocalPool()->free(objects[i]);
        }

        // Thread exits here, triggering gatherer logic
        // for the partial current bin with 20 objects
    });

    t.join();

    // Main thread should be able to allocate - objects from partial bin
    // should have been gathered into full bin
    TestObject* obj = pool.getLocalPool()->allocate();
    assert(obj != nullptr);
    pool.getLocalPool()->free(obj);

    std::cout << "PASS\n";
}

// Test 8: Empty bin handling
void test_empty_bin() {
    std::cout << "Test 8: Empty bin handling... ";

    objectsCreated = 0;
    ObjectPoolManager<TestObject> pool(createTestObject, 64);

    // Allocate and free in exact bin-size chunks
    for (int round = 0; round < 3; ++round) {
        std::vector<TestObject*> objects;

        // Allocate exactly 64 objects (one bin)
        for (int i = 0; i < 64; ++i) {
            objects.push_back(pool.getLocalPool()->allocate());
        }

        // Free all (should create empty bin)
        for (auto* obj : objects) {
            pool.getLocalPool()->free(obj);
        }
    }

    std::cout << "PASS\n";
}

// Test 9: Large allocation
void test_large_allocation() {
    std::cout << "Test 9: Large allocation (1000 objects)... ";

    objectsCreated = 0;
    ObjectPoolManager<TestObject> pool(createTestObject, 64);

    std::vector<TestObject*> objects;

    // Allocate 1000 objects
    for (int i = 0; i < 1000; ++i) {
        TestObject* obj = pool.getLocalPool()->allocate();
        assert(obj != nullptr);
        obj->value = i;
        objects.push_back(obj);
    }

    // Verify values
    for (int i = 0; i < 1000; ++i) {
        assert(objects[i]->value == i);
    }

    // Free all
    for (auto* obj : objects) {
        pool.getLocalPool()->free(obj);
    }

    std::cout << "PASS\n";
}

// Test 10: Global pool limits
void test_global_pool_limits() {
    std::cout << "Test 10: Global pool limits... ";

    objectsCreated = 0;
    // Small global pool limit to test overflow behavior
    ObjectPoolManager<TestObject> pool(createTestObject,
                                       64,   // bin size
                                       2,    // initial full bins
                                       2,    // initial empty bins
                                       10,   // max global bins (small)
                                       2,    // max full per thread
                                       2);   // max empty per thread

    std::vector<TestObject*> objects;

    // Allocate many objects to force bin creation
    for (int i = 0; i < 500; ++i) {
        objects.push_back(pool.getLocalPool()->allocate());
    }

    // Free all - will create many bins, testing global limit
    for (auto* obj : objects) {
        pool.getLocalPool()->free(obj);
    }

    // Should still work
    TestObject* obj = pool.getLocalPool()->allocate();
    assert(obj != nullptr);
    pool.getLocalPool()->free(obj);

    std::cout << "PASS\n";
}

int main() {
    std::cout << "=== Object Pool Unit Tests ===\n\n";

    test_basic_alloc_free();
    test_bin_overflow();
    test_bin_underflow();
    test_thread_local_caching();
    test_object_reuse();
    test_multithreaded();
    test_gatherer_bin();
    test_empty_bin();
    test_large_allocation();
    test_global_pool_limits();

    std::cout << "\n=== All tests passed! ===\n";

    return 0;
}
