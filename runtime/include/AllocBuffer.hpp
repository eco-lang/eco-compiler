#ifndef ECO_ALLOCBUFFER_H
#define ECO_ALLOCBUFFER_H

#include <cstddef>

namespace Elm {

/**
 * An allocation buffer for fast bump-pointer allocation into old gen.
 * Provides O(1) allocation by simply incrementing a pointer.
 */
class AllocBuffer {
public:
    /**
     * Create an AllocBuffer from a memory region.
     * @param base Start of the memory region
     * @param size Size of the region in bytes
     */
    AllocBuffer(char* base, size_t size)
        : start(base), end(base + size), alloc_ptr(base) {}

    /**
     * Allocate from this buffer using bump pointer.
     *
     * @param size Number of bytes to allocate (will be 8-byte aligned)
     * @return Pointer to allocated memory, or nullptr if buffer exhausted
     */
    void* allocate(size_t size) {
        // Align to 8 bytes.
        size = (size + 7) & ~7;

        // Check if we have space.
        if (alloc_ptr + size > end) {
            return nullptr;  // Buffer exhausted.
        }

        // Bump pointer allocation.
        void* result = alloc_ptr;
        alloc_ptr += size;
        return result;
    }

    // ========== Query Methods ==========

    // Returns the number of bytes allocated from this buffer.
    size_t bytesUsed() const { return alloc_ptr - start; }

    // Returns the number of bytes still available in this buffer.
    size_t bytesRemaining() const { return end - alloc_ptr; }

    // Returns the total capacity of this buffer in bytes.
    size_t capacity() const { return end - start; }

    // Returns true if no allocations have been made from this buffer.
    bool isEmpty() const { return alloc_ptr == start; }

    // Returns true if this buffer has no remaining space.
    bool isFull() const { return alloc_ptr == end; }

    // ========== Memory Region ==========

    char* start;      // Start of buffer memory region.
    char* end;        // End of buffer memory region (exclusive).
    char* alloc_ptr;  // Current bump pointer for next allocation.
};

} // namespace Elm

#endif // ECO_ALLOCBUFFER_H
