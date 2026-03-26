#include "StackMap.hpp"
#include <cassert>
#include <cstring>

namespace Elm {

//===----------------------------------------------------------------------===//
// Binary reader helper
//===----------------------------------------------------------------------===//

namespace {

class BinaryReader {
public:
    BinaryReader(const uint8_t* data, size_t size)
        : data_(data), size_(size), pos_(0) {}

    bool hasRemaining(size_t n) const { return pos_ + n <= size_; }

    uint8_t readU8() {
        assert(hasRemaining(1));
        return data_[pos_++];
    }

    uint16_t readU16() {
        assert(hasRemaining(2));
        uint16_t val;
        std::memcpy(&val, data_ + pos_, 2);
        pos_ += 2;
        return val;
    }

    uint32_t readU32() {
        assert(hasRemaining(4));
        uint32_t val;
        std::memcpy(&val, data_ + pos_, 4);
        pos_ += 4;
        return val;
    }

    int32_t readI32() {
        assert(hasRemaining(4));
        int32_t val;
        std::memcpy(&val, data_ + pos_, 4);
        pos_ += 4;
        return val;
    }

    uint64_t readU64() {
        assert(hasRemaining(8));
        uint64_t val;
        std::memcpy(&val, data_ + pos_, 8);
        pos_ += 8;
        return val;
    }

    void skip(size_t n) {
        assert(hasRemaining(n));
        pos_ += n;
    }

    // Align position to a multiple of `alignment`.
    void alignTo(size_t alignment) {
        size_t rem = pos_ % alignment;
        if (rem != 0)
            pos_ += alignment - rem;
    }

    size_t position() const { return pos_; }

private:
    const uint8_t* data_;
    size_t size_;
    size_t pos_;
};

} // anonymous namespace

//===----------------------------------------------------------------------===//
// StackMap parsing (LLVM Stack Map format v3)
//
// Reference: https://llvm.org/docs/StackMaps.html#stack-map-format
//
// Header:
//   uint8  version (3)
//   uint8  reserved
//   uint16 reserved
//   uint32 numFunctions
//   uint32 numConstants
//   uint32 numRecords
//
// Function entries (numFunctions):
//   uint64 address
//   uint64 stackSize
//   uint64 recordCount
//
// Constants (numConstants):
//   uint64 value
//
// Records (numRecords):
//   uint64 patchPointID
//   uint32 instructionOffset
//   uint16 reserved
//   uint16 numLocations
//   Location entries (numLocations, 12 bytes each in v3):
//     uint16 kind (byte 0 is kind, byte 1 reserved)
//     uint16 sizeInBytes
//     uint32 dwarfRegNum
//     int32  offset/smallConstant
//   padding (align to 8)
//   uint16 numLiveOuts
//   LiveOut entries (numLiveOuts):
//     uint16 dwarfRegNum
//     uint8  reserved
//     uint8  sizeInBytes
//   uint32 padding (align to 8)
//===----------------------------------------------------------------------===//

bool StackMap::parse(const uint8_t* data, size_t size) {
    records_.clear();
    functions_.clear();
    constants_.clear();

    if (size < 16)
        return false;

    BinaryReader reader(data, size);

    // Header
    uint8_t version = reader.readU8();
    if (version != 3)
        return false; // Only support v3

    reader.skip(1);  // reserved
    reader.skip(2);  // reserved

    uint32_t numFunctions = reader.readU32();
    uint32_t numConstants = reader.readU32();
    uint32_t numRecords = reader.readU32();

    // Function entries
    functions_.resize(numFunctions);
    for (uint32_t i = 0; i < numFunctions; i++) {
        functions_[i].address = reader.readU64();
        functions_[i].stackSize = reader.readU64();
        functions_[i].recordCount = reader.readU64();
    }

    // Constants
    constants_.resize(numConstants);
    for (uint32_t i = 0; i < numConstants; i++) {
        constants_[i] = reader.readU64();
    }

    // Records — associate each with its function to compute return addresses
    uint32_t funcIdx = 0;
    uint32_t recordsForFunc = 0;

    for (uint32_t i = 0; i < numRecords; i++) {
        // Advance to next function if needed
        while (funcIdx < numFunctions &&
               recordsForFunc >= functions_[funcIdx].recordCount) {
            recordsForFunc = 0;
            funcIdx++;
        }

        StackMapRecord record;
        record.patchPointID = reader.readU64();
        record.instructionOffset = reader.readU32();

        reader.skip(2); // reserved
        uint16_t numLocations = reader.readU16();

        record.locations.resize(numLocations);
        for (uint16_t j = 0; j < numLocations; j++) {
            auto& loc = record.locations[j];
            // v3 location format (12 bytes):
            //   [0:1]  uint16_t kind (byte 0 is kind, byte 1 reserved)
            //   [2:3]  uint16_t sizeInBytes
            //   [4:7]  uint32_t dwarfRegNum  (note: 32-bit in v3!)
            //   [8:11] int32_t  offset/smallConstant
            uint16_t kindField = reader.readU16();
            loc.kind = static_cast<StackMapLocation::Kind>(kindField & 0xFF);
            loc.sizeInBytes = reader.readU16();
            loc.dwarfRegNum = static_cast<uint16_t>(reader.readU32());
            loc.offset = reader.readI32();
        }

        // After locations: padding to align to 8 bytes (v3 format)
        reader.alignTo(8);

        // Live-outs
        reader.skip(2); // padding
        uint16_t numLiveOuts = reader.readU16();
        for (uint16_t j = 0; j < numLiveOuts; j++) {
            reader.skip(2); // dwarfRegNum
            reader.skip(1); // reserved
            reader.skip(1); // sizeInBytes
        }

        // Padding to align to 8 bytes after live-outs
        reader.alignTo(8);

        // Compute return address: function base + instruction offset
        if (funcIdx < numFunctions) {
            uint64_t returnAddr =
                functions_[funcIdx].address + record.instructionOffset;
            records_[returnAddr] = std::move(record);
        }

        recordsForFunc++;
    }

    return true;
}

const StackMapRecord* StackMap::findRecord(uint64_t returnAddress) const {
    auto it = records_.find(returnAddress);
    if (it == records_.end())
        return nullptr;
    return &it->second;
}

// Global stack map instance
static StackMap g_stackMap;

StackMap& globalStackMap() {
    return g_stackMap;
}

} // namespace Elm
