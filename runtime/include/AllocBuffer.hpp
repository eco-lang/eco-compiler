#ifndef ECO_ALLOCBUFFER_H
#define ECO_ALLOCBUFFER_H

#include <cstddef>

namespace Elm {

// Forward declaration for friend access.
class OldGenSpace;

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
        : start_(base), end_(base + size), alloc_ptr_(base) {}

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
        if (alloc_ptr_ + size > end_) {
            return nullptr;  // Buffer exhausted.
        }

        // Bump pointer allocation.
        void* result = alloc_ptr_;
        alloc_ptr_ += size;
        return result;
    }

private:
    char* start_;      // Start of buffer memory region.
    char* end_;        // End of buffer memory region (exclusive).
    char* alloc_ptr_;  // Current bump pointer for next allocation.

    friend class OldGenSpace;
};

} // namespace Elm

#endif // ECO_ALLOCBUFFER_H
