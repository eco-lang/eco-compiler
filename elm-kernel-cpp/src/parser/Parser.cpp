/**
 * Elm Kernel Parser Module - Runtime Heap Integration
 *
 * Provides string parsing utilities using GC-managed heap values.
 */

#include "Parser.hpp"
#include "allocator/Allocator.hpp"

namespace Elm::Kernel::Parser {

// Helper to check if code unit is a high surrogate
static bool isHighSurrogate(u16 c) {
    return (c & 0xF800) == 0xD800;
}

// Helper to extract code point from surrogate pair or single unit
static u32 getCodePoint(ElmString* s, i64 offset, i64& advance) {
    u16 c = s->chars[offset];
    if (isHighSurrogate(c) && static_cast<u32>(offset + 1) < s->header.size) {
        u16 low = s->chars[offset + 1];
        if (low >= 0xDC00 && low <= 0xDFFF) {
            advance = 2;
            return 0x10000 + ((c - 0xD800) << 10) + (low - 0xDC00);
        }
    }
    advance = 1;
    return static_cast<u32>(c);
}

bool isAsciiCode(u16 code, i64 offset, void* str) {
    ElmString* s = static_cast<ElmString*>(str);

    if (offset < 0 || static_cast<u32>(offset) >= s->header.size) {
        return false;
    }
    return s->chars[offset] == code;
}

i64 isSubChar(CharPredicate predicate, i64 offset, void* str) {
    ElmString* s = static_cast<ElmString*>(str);

    if (offset < 0 || static_cast<u32>(offset) >= s->header.size) {
        return -1;
    }

    i64 advance;
    u32 codePoint = getCodePoint(s, offset, advance);

    if (!predicate(codePoint)) {
        return -1;
    }

    // Check for newline
    if (codePoint == '\n') {
        return -2;
    }

    return offset + advance;
}

HPointer isSubString(void* sub, i64 offset, i64 row, i64 col, void* str) {
    ElmString* subStr = static_cast<ElmString*>(sub);
    ElmString* bigStr = static_cast<ElmString*>(str);

    i64 smallLength = static_cast<i64>(subStr->header.size);

    // Check if there's enough space
    bool isGood = (offset >= 0 && static_cast<u32>(offset + smallLength) <= bigStr->header.size);

    i64 i = 0;
    while (isGood && i < smallLength) {
        u16 code = bigStr->chars[offset];

        // Check character match
        isGood = (subStr->chars[i++] == bigStr->chars[offset++]);

        if (isGood) {
            if (code == 0x000A) {
                // Newline
                row++;
                col = 1;
            } else {
                col++;
                // Handle surrogate pair
                if (isHighSurrogate(code) && i < smallLength) {
                    isGood = (subStr->chars[i++] == bigStr->chars[offset++]);
                }
            }
        }
    }

    i64 resultOffset = isGood ? offset : -1;
    return alloc::tuple3(
        alloc::unboxedInt(resultOffset),
        alloc::unboxedInt(row),
        alloc::unboxedInt(col),
        0x7  // All unboxed
    );
}

HPointer findSubString(void* sub, i64 offset, i64 row, i64 col, void* str) {
    ElmString* subStr = static_cast<ElmString*>(sub);
    ElmString* bigStr = static_cast<ElmString*>(str);

    i64 subLen = static_cast<i64>(subStr->header.size);
    i64 bigLen = static_cast<i64>(bigStr->header.size);

    // Simple search for substring
    i64 index = -1;
    if (subLen > 0) {
        for (i64 pos = offset; pos + subLen <= bigLen; pos++) {
            bool match = true;
            for (i64 j = 0; j < subLen && match; j++) {
                if (subStr->chars[j] != bigStr->chars[pos + j]) {
                    match = false;
                }
            }
            if (match) {
                index = pos;
                break;
            }
        }
    }

    bool found = (index >= 0);
    i64 target = found ? (index + subLen) : bigLen;

    while (offset < target) {
        u16 code = bigStr->chars[offset++];

        if (code == 0x000A) {
            col = 1;
            row++;
        } else {
            col++;
            // Skip second unit of surrogate pair
            if (isHighSurrogate(code) && offset < target) {
                offset++;
            }
        }
    }

    i64 resultOffset = found ? target : -1;
    return alloc::tuple3(
        alloc::unboxedInt(resultOffset),
        alloc::unboxedInt(row),
        alloc::unboxedInt(col),
        0x7  // All unboxed
    );
}

HPointer consumeBase(i64 base, i64 offset, void* str) {
    ElmString* s = static_cast<ElmString*>(str);
    i64 total = 0;

    while (offset >= 0 && static_cast<u32>(offset) < s->header.size) {
        i64 digit = s->chars[offset] - 0x30;
        if (digit < 0 || digit >= base) {
            break;
        }
        total = base * total + digit;
        offset++;
    }

    return alloc::tuple2(
        alloc::unboxedInt(offset),
        alloc::unboxedInt(total),
        0x3  // Both unboxed
    );
}

HPointer consumeBase16(i64 offset, void* str) {
    ElmString* s = static_cast<ElmString*>(str);
    i64 total = 0;

    while (offset >= 0 && static_cast<u32>(offset) < s->header.size) {
        u16 code = s->chars[offset];

        if (code >= 0x30 && code <= 0x39) {
            // '0'-'9'
            total = 16 * total + (code - 0x30);
        } else if (code >= 0x41 && code <= 0x46) {
            // 'A'-'F' -> 10-15
            total = 16 * total + (code - 55);
        } else if (code >= 0x61 && code <= 0x66) {
            // 'a'-'f' -> 10-15
            total = 16 * total + (code - 87);
        } else {
            break;
        }
        offset++;
    }

    return alloc::tuple2(
        alloc::unboxedInt(offset),
        alloc::unboxedInt(total),
        0x3  // Both unboxed
    );
}

i64 chompBase10(i64 offset, void* str) {
    ElmString* s = static_cast<ElmString*>(str);

    while (offset >= 0 && static_cast<u32>(offset) < s->header.size) {
        u16 code = s->chars[offset];
        if (code < 0x30 || code > 0x39) {
            return offset;
        }
        offset++;
    }
    return offset;
}

} // namespace Elm::Kernel::Parser
