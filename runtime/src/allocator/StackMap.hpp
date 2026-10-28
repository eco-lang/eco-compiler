#ifndef ECO_STACKMAP_H
#define ECO_STACKMAP_H

// A collector that moves objects has to find every GC pointer held in a stack frame of compiled
// code, and only the compiler knows where those are. LLVM records them. At each statepoint, a call
// site at which a collection may happen, it writes a stack map record listing where each value
// live across the call is kept, and it emits the records in a `__LLVM_StackMaps` section in the
// LLVM stack map format, version 3. This component reads such a section into a table that a stack
// walk can query.
//
// A record is found by its return address: the function's start address plus the record's
// instruction offset. The table relies on LLVM placing a statepoint's offset just after the call,
// so that this sum is the address the called function returns to, which is what a walker knows
// about each frame.
//
// One section may hold several blobs one after another, each with its own v3 header.
// `StackMap::parse` reads them all into one table.
//
// Most frames a walk visits belong to code with no records. `findRecord` therefore first compares
// an address with the lowest and highest return addresses parsed, and rejects one outside that
// span without a hash lookup.

#include <cstddef>
#include <cstdint>
#include <vector>
#include <unordered_map>

namespace Elm {

/// One location in a stack map record: where one value live at the statepoint is kept.
struct StackMapLocation {
    /// How a location finds its value.
    ///
    /// The numbers are those of the LLVM stack map format and are read from the binary, so they must
    /// not be renumbered. `parse` casts the byte it reads without checking it, so a `kind` may hold a
    /// value outside this set.
    enum Kind : uint8_t {
        Register = 1,     ///< The value is in register `dwarfRegNum`.
        Direct = 2,       ///< The value is the contents of register `dwarfRegNum` plus `offset`.
        Indirect = 3,     ///< The value is in memory at the contents of register `dwarfRegNum` plus `offset`.
        Constant = 4,     ///< The value is `offset` itself.
        ConstantIndex = 5 ///< The value is in the constant pool, at the index held in `offset`.
    };

    Kind kind;
    /// A DWARF register number. The format stores 16 bits, then a reserved 16-bit field that `parse` discards.
    uint16_t dwarfRegNum;
    int32_t offset;        ///< See `Kind` for what it means for each kind.
    uint32_t sizeInBytes;
};

/// The stack map record of one statepoint: the locations of the values live across it.
struct StackMapRecord {
    uint64_t patchPointID;        ///< The ID LLVM recorded for the statepoint. Nothing in the runtime reads it.
    uint32_t instructionOffset;   ///< Bytes from the function's start address to the return address.
    std::vector<StackMapLocation> locations;
};

/// One function entry of a stack map blob.
struct StackMapFunction {
    uint64_t address;     ///< The start address in the blob plus the `loadBase` given to `parse`.
    uint64_t stackSize;
    /// How many consecutive records of the blob, after those of the entries before it, belong to
    /// this function.
    uint64_t recordCount;
};

/// A table from return address to the record of the statepoint there, read from one
/// `__LLVM_StackMaps` section.
///
/// It is empty until `parse` fills it. It has no lock: `parse` must not run while any other thread
/// is using the same map.
class StackMap {
public:
    /// Replaces the table's records with those of the section held in the `size` bytes at `data`,
    /// and returns whether at least one blob was read.
    ///
    /// `loadBase` is added to every function address in the section. Pass 0 when those addresses
    /// are already the ones the code runs at. `data` is copied from and not kept.
    ///
    /// Blobs are read from the start, each beginning at the next multiple of 8 bytes from `data`.
    /// Reading stops at the end of the section, where fewer than 16 bytes remain, or at a blob
    /// whose version byte is not 3; what follows is ignored. Records beyond those the blob's
    /// function entries account for are dropped. Of two records with the same return address, the
    /// later one is kept.
    ///
    /// The previous records are discarded even when this returns false, so a failed parse leaves
    /// the table empty. The bounds of a blob's tables are checked only by `assert`, so the section
    /// must be well formed: a truncated one is read past its end when assertions are off.
    ///
    /// It invalidates every pointer `findRecord` returned before.
    bool parse(const uint8_t* data, size_t size, uint64_t loadBase = 0);

    /// Returns the record whose return address is `returnAddress`, or null if there is none. The
    /// pointer is valid until the next `parse` or the map's destruction.
    const StackMapRecord* findRecord(uint64_t returnAddress) const;

    /// Returns whether the table holds any record.
    bool hasRecords() const { return !records_.empty(); }

    /// Returns the number of records in the table.
    size_t numRecords() const { return records_.size(); }

    /// Returns the number of function entries the last `parse` read, over all its blobs.
    size_t numFunctions() const { return functions_.size(); }

private:
    std::vector<StackMapFunction> functions_;
    // The constant pools of every blob, concatenated. Nothing reads it. A `ConstantIndex` location
    // indexes its own blob's pool, so it indexes this vector correctly only for the first blob.
    std::vector<uint64_t> constants_;

    // Keyed by return address.
    std::unordered_map<uint64_t, StackMapRecord> records_;

    // The [lo, hi) span of every return address added by any `parse` since construction. `parse`
    // does not reset it, so after a second `parse` it may be wider than the records it holds; an
    // address inside it with no record falls through to the hash lookup.
    uint64_t addr_lo_ = ~static_cast<uint64_t>(0);
    uint64_t addr_hi_ = 0;
};

/// Returns the process-wide stack map. It is empty until something parses a section into it.
StackMap& globalStackMap();

} // namespace Elm

#endif // ECO_STACKMAP_H
