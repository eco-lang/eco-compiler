#ifndef ECO_OBJECT_POOL_H
#define ECO_OBJECT_POOL_H

#include <cstddef>
#include <functional>
#include <mutex>
#include <queue>
#include <vector>

namespace Elm {

// Forward declarations
template<typename T> class ObjectPoolManager;
template<typename T> class ThreadLocalPool;

// ============================================================================
// ObjectBin - Stack-based container for object pointers
// ============================================================================

/**
 * ObjectBin holds a fixed-size array of object pointers, operating as a stack.
 * This corresponds to BoundedStack in the Java implementation.
 *
 * Thread-safety: NOT thread-safe (accessed only by owning thread)
 */
template<typename T>
class ObjectBin {
public:
    explicit ObjectBin(size_t capacity)
        : capacity_(capacity), top_(0) {
        objects_ = new T*[capacity];
    }

    ~ObjectBin() {
        delete[] objects_;
    }

    /**
     * Pop an object pointer from the bin.
     * @return Object pointer, or nullptr if bin is empty
     */
    T* pop() {
        if (isEmpty()) {
            return nullptr;
        }
        return objects_[--top_];
    }

    /**
     * Push an object pointer onto the bin.
     * @param obj Object pointer to push
     * @return true if successful, false if bin is full
     */
    bool push(T* obj) {
        if (isFull()) {
            return false;
        }
        objects_[top_++] = obj;
        return true;
    }

    // Query methods
    bool isEmpty() const { return top_ == 0; }
    bool isFull() const { return top_ == capacity_; }
    size_t size() const { return top_; }
    size_t capacity() const { return capacity_; }

private:
    T** objects_;      // Array of object pointers
    size_t capacity_;  // Maximum number of objects
    size_t top_;       // Points to next free slot (stack pointer)

    // Non-copyable
    ObjectBin(const ObjectBin&) = delete;
    ObjectBin& operator=(const ObjectBin&) = delete;
};

// ============================================================================
// ThreadLocalPool - Per-thread object cache
// ============================================================================

/**
 * ThreadLocalPool provides thread-local caching of object bins.
 * Corresponds to LocalBins in the Java implementation.
 *
 * Each thread maintains:
 * - A current bin (partially filled)
 * - Local cache of full bins
 * - Local cache of empty bins
 *
 * Thread-safety: NOT thread-safe (one instance per thread)
 */
template<typename T>
class ThreadLocalPool {
public:
    ThreadLocalPool(ObjectPoolManager<T>* manager,
                   size_t maxFullBins,
                   size_t maxEmptyBins)
        : manager_(manager),
          currentBin_(nullptr),
          maxFullBins_(maxFullBins),
          maxEmptyBins_(maxEmptyBins) {
        localFullBins_.reserve(maxFullBins);
        localEmptyBins_.reserve(maxEmptyBins);
    }

    ~ThreadLocalPool() {
        releaseCache();
    }

    /**
     * Allocate an object from the pool.
     * Fast path - no locks in common case.
     *
     * @return Object pointer (caller must initialize)
     */
    T* allocate() {
        // If current bin is empty, return it to empty cache and get a full bin
        if (currentBin_ && currentBin_->isEmpty()) {
            if (localEmptyBins_.size() >= maxEmptyBins_) {
                // Local empty cache full, return to global pool
                manager_->returnEmptyBin(currentBin_);
            } else {
                // Add to local empty cache
                localEmptyBins_.push_back(currentBin_);
            }
            currentBin_ = nullptr;
        }

        // Get a full bin if we don't have a current bin
        if (!currentBin_) {
            if (!localFullBins_.empty()) {
                // Use local full bin
                currentBin_ = localFullBins_.back();
                localFullBins_.pop_back();
            } else {
                // Get from global pool
                currentBin_ = manager_->getFullBin();
            }
        }

        // Allocate from current bin
        return currentBin_->pop();
    }

    /**
     * Return an object to the pool.
     * Fast path - no locks in common case.
     *
     * @param obj Object pointer to return
     */
    void free(T* obj) {
        // If current bin is full, return it to full cache and get an empty bin
        if (currentBin_ && currentBin_->isFull()) {
            if (localFullBins_.size() >= maxFullBins_) {
                // Local full cache full, return to global pool
                manager_->returnFullBin(currentBin_);
            } else {
                // Add to local full cache
                localFullBins_.push_back(currentBin_);
            }
            currentBin_ = nullptr;
        }

        // Get an empty bin if we don't have a current bin
        if (!currentBin_) {
            if (!localEmptyBins_.empty()) {
                // Use local empty bin
                currentBin_ = localEmptyBins_.back();
                localEmptyBins_.pop_back();
            } else {
                // Get from global pool
                currentBin_ = manager_->getEmptyBin();
            }
        }

        // Return to current bin
        currentBin_->push(obj);
    }

    /**
     * Release all cached bins back to global pool.
     * Called on thread exit.
     */
    void releaseCache() {
        if (!manager_) {
            // Manager already destroyed, skip cleanup
            return;
        }

        // Return all full bins to global pool
        for (auto* bin : localFullBins_) {
            manager_->returnFullBin(bin);
        }
        localFullBins_.clear();

        // Handle current bin
        if (currentBin_) {
            if (currentBin_->isFull()) {
                // Current bin is full, return to global pool
                manager_->returnFullBin(currentBin_);
            } else if (!currentBin_->isEmpty()) {
                // Current bin is partial, use gatherer to consolidate
                manager_->gatherPartialBin(currentBin_);
            } else {
                // Current bin is empty, just discard
                delete currentBin_;
            }
            currentBin_ = nullptr;
        }

        // Empty bins can be discarded (no objects to preserve)
        for (auto* bin : localEmptyBins_) {
            delete bin;
        }
        localEmptyBins_.clear();
    }

private:
    ObjectPoolManager<T>* manager_;
    ObjectBin<T>* currentBin_;
    std::vector<ObjectBin<T>*> localFullBins_;
    std::vector<ObjectBin<T>*> localEmptyBins_;
    size_t maxFullBins_;
    size_t maxEmptyBins_;
};

// ============================================================================
// ObjectPoolManager - Global pool coordinator
// ============================================================================

/**
 * ObjectPoolManager manages global pools of object bins and coordinates
 * thread-local caches. Corresponds to ThreadLocalAllocator in Java.
 *
 * Features:
 * - Global full/empty bin pools (thread-safe)
 * - Thread-local pool instances (via thread_local)
 * - Gatherer bin for consolidating partial bins on thread exit
 * - Factory function for creating new objects
 *
 * Thread-safety: Global pools are mutex-protected
 */
template<typename T>
class ObjectPoolManager {
public:
    using FactoryFunc = std::function<T*()>;

    /**
     * Create an object pool manager.
     *
     * @param factory Function to create new objects
     * @param binSize Number of objects per bin (default: 64)
     * @param initialFullBins Number of full bins to pre-allocate (default: 16)
     * @param initialEmptyBins Number of empty bins to pre-allocate (default: 16)
     * @param maxGlobalBins Maximum size of global pools (default: 256)
     * @param maxFullBinsPerThread Maximum full bins cached per thread (default: 8)
     * @param maxEmptyBinsPerThread Maximum empty bins cached per thread (default: 8)
     */
    ObjectPoolManager(FactoryFunc factory,
                     size_t binSize = 64,
                     size_t initialFullBins = 16,
                     size_t initialEmptyBins = 16,
                     size_t maxGlobalBins = 256,
                     size_t maxFullBinsPerThread = 8,
                     size_t maxEmptyBinsPerThread = 8)
        : factory_(factory),
          binSize_(binSize),
          maxGlobalBins_(maxGlobalBins),
          maxFullBinsPerThread_(maxFullBinsPerThread),
          maxEmptyBinsPerThread_(maxEmptyBinsPerThread),
          gathererBin_(nullptr) {

        // Pre-allocate initial bins
        for (size_t i = 0; i < initialFullBins; ++i) {
            fullBins_.push(createFullBin());
        }
        for (size_t i = 0; i < initialEmptyBins; ++i) {
            emptyBins_.push(createEmptyBin());
        }
    }

    ~ObjectPoolManager() {
        // Clean up global bins
        // Note: Objects in bins are managed elsewhere, we just delete bin metadata
        while (!fullBins_.empty()) {
            auto* bin = fullBins_.front();
            fullBins_.pop();
            delete bin;
        }
        while (!emptyBins_.empty()) {
            auto* bin = emptyBins_.front();
            emptyBins_.pop();
            delete bin;
        }
        if (gathererBin_) {
            delete gathererBin_;
        }
    }

    /**
     * Get the thread-local pool for this thread.
     * Lazily creates pool on first access.
     *
     * @return Thread-local pool instance
     */
    ThreadLocalPool<T>* getLocalPool() {
        if (!localPool_) {
            localPool_ = new ThreadLocalPool<T>(
                this,
                maxFullBinsPerThread_,
                maxEmptyBinsPerThread_
            );
        }
        return localPool_;
    }

    /**
     * Get a full bin from the global pool.
     * Called by ThreadLocalPool when local cache is empty.
     * Creates a new bin if global pool is empty.
     *
     * Thread-safety: Mutex-protected
     *
     * @return Full bin (never null)
     */
    ObjectBin<T>* getFullBin() {
        std::lock_guard<std::mutex> lock(fullBinsMutex_);

        if (!fullBins_.empty()) {
            auto* bin = fullBins_.front();
            fullBins_.pop();
            return bin;
        }

        // Global pool empty, create new full bin
        return createFullBin();
    }

    /**
     * Get an empty bin from the global pool.
     * Called by ThreadLocalPool when local cache is empty.
     * Creates a new bin if global pool is empty.
     *
     * Thread-safety: Mutex-protected
     *
     * @return Empty bin (never null)
     */
    ObjectBin<T>* getEmptyBin() {
        std::lock_guard<std::mutex> lock(emptyBinsMutex_);

        if (!emptyBins_.empty()) {
            auto* bin = emptyBins_.front();
            emptyBins_.pop();
            return bin;
        }

        // Global pool empty, create new empty bin
        return createEmptyBin();
    }

    /**
     * Return a full bin to the global pool.
     * Called by ThreadLocalPool when local cache overflows.
     * Discards bin if global pool is at capacity.
     *
     * Thread-safety: Mutex-protected
     *
     * @param bin Full bin to return
     */
    void returnFullBin(ObjectBin<T>* bin) {
        std::lock_guard<std::mutex> lock(fullBinsMutex_);

        if (fullBins_.size() < maxGlobalBins_) {
            fullBins_.push(bin);
        } else {
            // Global pool full, discard bin
            delete bin;
        }
    }

    /**
     * Return an empty bin to the global pool.
     * Called by ThreadLocalPool when local cache overflows.
     * Discards bin if global pool is at capacity.
     *
     * Thread-safety: Mutex-protected
     *
     * @param bin Empty bin to return
     */
    void returnEmptyBin(ObjectBin<T>* bin) {
        std::lock_guard<std::mutex> lock(emptyBinsMutex_);

        if (emptyBins_.size() < maxGlobalBins_) {
            emptyBins_.push(bin);
        } else {
            // Global pool full, discard bin
            delete bin;
        }
    }

    /**
     * Gather a partial bin into the gatherer bin.
     * Consolidates objects from partial bins on thread exit.
     * When gatherer becomes full, it's returned to the global pool.
     *
     * Thread-safety: Mutex-protected (gatherer bin is shared)
     *
     * @param partialBin Partial bin to gather
     */
    void gatherPartialBin(ObjectBin<T>* partialBin) {
        std::lock_guard<std::mutex> lock(gathererMutex_);

        while (!partialBin->isEmpty()) {
            // Create gatherer bin if needed
            if (!gathererBin_) {
                gathererBin_ = createEmptyBin();
            }

            // Transfer objects from partial bin to gatherer
            while (!partialBin->isEmpty() && !gathererBin_->isFull()) {
                T* obj = partialBin->pop();
                gathererBin_->push(obj);
            }

            // If gatherer is full, return it to pool and create new one
            if (gathererBin_->isFull()) {
                returnFullBin(gathererBin_);
                gathererBin_ = nullptr;
            }
        }

        // Partial bin is now empty, discard it
        delete partialBin;
    }

private:
    FactoryFunc factory_;
    size_t binSize_;
    size_t maxGlobalBins_;
    size_t maxFullBinsPerThread_;
    size_t maxEmptyBinsPerThread_;

    // Global full bins pool
    std::mutex fullBinsMutex_;
    std::queue<ObjectBin<T>*> fullBins_;

    // Global empty bins pool
    std::mutex emptyBinsMutex_;
    std::queue<ObjectBin<T>*> emptyBins_;

    // Gatherer bin for consolidating partial bins on thread exit
    std::mutex gathererMutex_;
    ObjectBin<T>* gathererBin_;

    // Thread-local pool instance
    static thread_local ThreadLocalPool<T>* localPool_;

    /**
     * Create a bin full of new objects using the factory.
     * @return Full bin
     */
    ObjectBin<T>* createFullBin() {
        auto* bin = new ObjectBin<T>(binSize_);
        for (size_t i = 0; i < binSize_; ++i) {
            T* obj = factory_();
            bin->push(obj);
        }
        return bin;
    }

    /**
     * Create an empty bin.
     * @return Empty bin
     */
    ObjectBin<T>* createEmptyBin() {
        return new ObjectBin<T>(binSize_);
    }
};

// Thread-local storage definition
template<typename T>
thread_local ThreadLocalPool<T>* ObjectPoolManager<T>::localPool_ = nullptr;

} // namespace Elm

#endif // ECO_OBJECT_POOL_H
