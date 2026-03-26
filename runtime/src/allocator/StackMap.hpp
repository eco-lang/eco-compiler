#ifndef ECO_STACKMAP_H
#define ECO_STACKMAP_H

#include <cstddef>
#include <cstdint>
#include <vector>
#include <unordered_map>

namespace Elm {

/// A location descriptor from the LLVM stack map.
/// Describes where a GC root value lives at a safepoint.
struct StackMapLocation {
    enum Kind : uint8_t {
        Register = 1,     // Value in a register
        Direct = 2,       // Value at register + offset (frame slot address)
        Indirect = 3,     // Value at *(register + offset) (value on stack)
        Constant = 4,     // Small constant value
        ConstantIndex = 5 // Large constant (index into constant pool)
    };

    Kind kind;
    uint16_t dwarfRegNum;  // DWARF register number
    int32_t offset;        // Offset from register (for Direct/Indirect)
    uint32_t sizeInBytes;  // Size of the value
};

/// A single stack map record corresponding to one safepoint.
struct StackMapRecord {
    uint64_t patchPointID;        // Statepoint ID (always 0 for our safepoints)
    uint32_t instructionOffset;   // Offset from function entry to safepoint
    std::vector<StackMapLocation> locations;
};

/// Function entry in the stack map.
struct StackMapFunction {
    uint64_t address;     // Function start address (filled at load time)
    uint64_t stackSize;   // Stack frame size
    uint64_t recordCount; // Number of records for this function
};

/// Parsed LLVM stack map.
/// Maps return addresses to the set of GC root stack locations.
class StackMap {
public:
    /// Parse a raw __LLVM_StackMaps section.
    /// Returns true on success.
    bool parse(const uint8_t* data, size_t size);

    /// Look up stack root locations for a given return address.
    /// Returns nullptr if no record exists for this address.
    const StackMapRecord* findRecord(uint64_t returnAddress) const;

    /// Returns true if the stack map has any records.
    bool hasRecords() const { return !records_.empty(); }

    /// Number of parsed records.
    size_t numRecords() const { return records_.size(); }

    /// Number of parsed functions.
    size_t numFunctions() const { return functions_.size(); }

private:
    std::vector<StackMapFunction> functions_;
    std::vector<uint64_t> constants_;

    /// Keyed by return address (function address + instruction offset).
    std::unordered_map<uint64_t, StackMapRecord> records_;
};

/// Global stack map instance for JIT-compiled code.
/// Set by the JIT engine after compilation, read by the GC.
StackMap& globalStackMap();

} // namespace Elm

#endif // ECO_STACKMAP_H
