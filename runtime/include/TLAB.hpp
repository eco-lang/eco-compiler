#ifndef ECO_TLAB_H
#define ECO_TLAB_H

#include <cstddef>

namespace Elm {

/**
 * A thread-local allocation buffer for fast, lock-free allocation into old gen.
 * Each thread gets a TLAB for promoting objects during minor GC, avoiding
 * mutex contention on the global OldGenSpace free-list.
 */
class TLAB {
public:
    /**
     * Create a TLAB from a memory region.
     * @param base Start of the memory region
     * @param size Size of the region in bytes
     */
    TLAB(char* base, size_t size)
        : start(base), end(base + size), alloc_ptr(base) {}

    /**
     * Allocate from this TLAB using thread-local bump pointer.
     * NO SYNCHRONIZATION - thread has exclusive access.
     *
     * @param size Number of bytes to allocate (will be 8-byte aligned)
     * @return Pointer to allocated memory, or nullptr if TLAB exhausted
     */
    void* allocate(size_t size) {
        // Align to 8 bytes
        size = (size + 7) & ~7;

        // Check if we have space
        if (alloc_ptr + size > end) {
            return nullptr; // TLAB exhausted
        }

        // Bump pointer allocation (thread-local, no sync!)
        void* result = alloc_ptr;
        alloc_ptr += size;
        return result;
    }

    // ========== Query Methods ==========

    // Returns the number of bytes allocated from this TLAB.
    size_t bytesUsed() const { return alloc_ptr - start; }

    // Returns the number of bytes still available in this TLAB.
    size_t bytesRemaining() const { return end - alloc_ptr; }

    // Returns the total capacity of this TLAB in bytes.
    size_t capacity() const { return end - start; }

    // Returns true if no allocations have been made from this TLAB.
    bool isEmpty() const { return alloc_ptr == start; }

    // Returns true if this TLAB has no remaining space.
    bool isFull() const { return alloc_ptr == end; }

    // ========== Memory Region ==========

    char* start;      // Start of TLAB memory region.
    char* end;        // End of TLAB memory region (exclusive).
    char* alloc_ptr;  // Current bump pointer for next allocation.
};

} // namespace Elm

#endif // ECO_TLAB_H
