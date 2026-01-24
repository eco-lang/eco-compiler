# bf Dialect Test Plan

**Location:** `test/bf-codegen/`

**Purpose:** Comprehensive test coverage for the bf (byte fusion) MLIR dialect operations used in fused bytes encoding/decoding.

**Test Format:** MLIR FileCheck tests following the pattern in `test/codegen/`

---

## Test Categories

### 1. Buffer Allocation and Cursor Initialization (4 tests)

| Test File | Description |
|-----------|-------------|
| `bf_alloc_basic.mlir` | Basic bf.alloc with small buffer |
| `bf_alloc_zero.mlir` | bf.alloc with zero bytes |
| `bf_alloc_large.mlir` | bf.alloc with large size (1MB) |
| `bf_cursor_init.mlir` | bf.cursor.init from allocated buffer |

---

### 2. Primitive Write Operations - Encoder (15 tests)

| Test File | Description |
|-----------|-------------|
| `bf_write_u8.mlir` | Write single u8 value |
| `bf_write_u8_boundary.mlir` | Write u8 edge cases: 0, 127, 255 |
| `bf_write_u16_be.mlir` | Write u16 big-endian |
| `bf_write_u16_le.mlir` | Write u16 little-endian |
| `bf_write_u16_boundary.mlir` | Write u16 edge cases: 0, 32767, 65535 |
| `bf_write_u32_be.mlir` | Write u32 big-endian |
| `bf_write_u32_le.mlir` | Write u32 little-endian |
| `bf_write_u32_boundary.mlir` | Write u32 edge: 0, max_i32, max_u32 |
| `bf_write_f32_be.mlir` | Write f32 big-endian |
| `bf_write_f32_le.mlir` | Write f32 little-endian |
| `bf_write_f32_special.mlir` | Write f32: NaN, Inf, -Inf, denormal |
| `bf_write_f64_be.mlir` | Write f64 big-endian |
| `bf_write_f64_le.mlir` | Write f64 little-endian |
| `bf_write_f64_special.mlir` | Write f64: NaN, Inf, -Inf, denormal |
| `bf_write_sequence.mlir` | Write multiple values sequentially |

---

### 3. Variable-Length Write Operations (6 tests)

| Test File | Description |
|-----------|-------------|
| `bf_write_bytes_copy.mlir` | Copy ByteBuffer payload |
| `bf_write_bytes_empty.mlir` | Copy empty ByteBuffer |
| `bf_write_utf8.mlir` | Write UTF-8 string bytes |
| `bf_write_utf8_ascii.mlir` | Write ASCII-only string |
| `bf_write_utf8_multibyte.mlir` | Write multi-byte UTF-8 chars |
| `bf_write_utf8_empty.mlir` | Write empty string |

---

### 4. Primitive Read Operations - Decoder (16 tests)

| Test File | Description |
|-----------|-------------|
| `bf_read_u8.mlir` | Read single u8 value |
| `bf_read_u8_boundary.mlir` | Read u8 edge cases |
| `bf_read_i8.mlir` | Read signed i8 value |
| `bf_read_i8_negative.mlir` | Read i8 negative values (-128, -1) |
| `bf_read_u16_be.mlir` | Read u16 big-endian |
| `bf_read_u16_le.mlir` | Read u16 little-endian |
| `bf_read_i16_be.mlir` | Read signed i16 big-endian |
| `bf_read_i16_le.mlir` | Read signed i16 little-endian |
| `bf_read_u32_be.mlir` | Read u32 big-endian |
| `bf_read_u32_le.mlir` | Read u32 little-endian |
| `bf_read_i32_be.mlir` | Read signed i32 big-endian |
| `bf_read_i32_le.mlir` | Read signed i32 little-endian |
| `bf_read_f32_be.mlir` | Read f32 big-endian |
| `bf_read_f32_le.mlir` | Read f32 little-endian |
| `bf_read_f64_be.mlir` | Read f64 big-endian |
| `bf_read_f64_le.mlir` | Read f64 little-endian |
| `bf_read_sequence.mlir` | Read multiple values sequentially |

---

### 5. Variable-Length Read Operations (5 tests)

| Test File | Description |
|-----------|-------------|
| `bf_read_bytes.mlir` | Read bytes with known length |
| `bf_read_bytes_empty.mlir` | Read zero bytes |
| `bf_read_utf8.mlir` | Read UTF-8 string |
| `bf_read_utf8_multibyte.mlir` | Read multi-byte UTF-8 string |
| `bf_read_utf8_empty.mlir` | Read empty string |

---

### 6. Bounds Checking - bf.require (4 tests)

| Test File | Description |
|-----------|-------------|
| `bf_require_pass.mlir` | bf.require succeeds when bytes available |
| `bf_require_fail.mlir` | bf.require fails at end of buffer |
| `bf_require_exact.mlir` | bf.require at exact buffer boundary |
| `bf_require_zero.mlir` | bf.require with zero bytes |

---

### 7. Roundtrip Tests - Encode then Decode (13 tests)

| Test File | Description |
|-----------|-------------|
| `bf_roundtrip_u8.mlir` | Write u8, read back, verify match |
| `bf_roundtrip_u16_be.mlir` | Write u16 BE, read back, verify |
| `bf_roundtrip_u16_le.mlir` | Write u16 LE, read back, verify |
| `bf_roundtrip_u32_be.mlir` | Write u32 BE, read back, verify |
| `bf_roundtrip_u32_le.mlir` | Write u32 LE, read back, verify |
| `bf_roundtrip_f32_be.mlir` | Write f32 BE, read back, verify |
| `bf_roundtrip_f32_le.mlir` | Write f32 LE, read back, verify |
| `bf_roundtrip_f64_be.mlir` | Write f64 BE, read back, verify |
| `bf_roundtrip_f64_le.mlir` | Write f64 LE, read back, verify |
| `bf_roundtrip_signed.mlir` | Roundtrip signed values (i8, i16, i32) |
| `bf_roundtrip_mixed.mlir` | Mixed types in sequence |
| `bf_roundtrip_bytes.mlir` | Write bytes, read back, verify |
| `bf_roundtrip_utf8.mlir` | Write UTF-8, read back, verify |

---

### 8. Decode-Encode Roundtrip - Start from bytes (3 tests)

| Test File | Description |
|-----------|-------------|
| `bf_decode_encode_u8.mlir` | Decode u8 from literal bytes, encode, compare |
| `bf_decode_encode_u32_be.mlir` | Decode u32 BE, encode, compare bytes |
| `bf_decode_encode_mixed.mlir` | Decode sequence, encode, compare |

---

### 9. Cursor Threading (3 tests)

| Test File | Description |
|-----------|-------------|
| `bf_cursor_chain.mlir` | Multiple writes with cursor threading |
| `bf_cursor_read_chain.mlir` | Multiple reads with cursor threading |
| `bf_cursor_mixed.mlir` | Interleaved cursor operations |

---

### 10. Loop Decode Tests - scf.while (5 tests)

| Test File | Description |
|-----------|-------------|
| `bf_loop_decode_empty.mlir` | Loop decode with count=0 |
| `bf_loop_decode_single.mlir` | Loop decode single item |
| `bf_loop_decode_multiple.mlir` | Loop decode multiple items |
| `bf_loop_decode_nested.mlir` | Nested loop decode (list of lists) |
| `bf_loop_decode_bounds_fail.mlir` | Loop decode fails mid-way |

---

### 11. Error Cases (4 tests)

| Test File | Description |
|-----------|-------------|
| `bf_read_past_end.mlir` | Attempt to read past buffer end |
| `bf_read_incomplete_u32.mlir` | Read u32 with only 2 bytes available |
| `bf_read_incomplete_f64.mlir` | Read f64 with only 4 bytes available |
| `bf_require_overflow.mlir` | bf.require more bytes than available |

---

### 12. Maybe Result Handling (2 tests)

| Test File | Description |
|-----------|-------------|
| `bf_decode_just.mlir` | Successful decode returns Just |
| `bf_decode_nothing.mlir` | Failed decode returns Nothing |

---

### 13. Endianness Verification (4 tests)

| Test File | Description |
|-----------|-------------|
| `bf_endian_u16_verify.mlir` | Verify BE vs LE gives different bytes |
| `bf_endian_u32_verify.mlir` | Verify u32 BE vs LE byte order |
| `bf_endian_f32_verify.mlir` | Verify f32 BE vs LE byte order |
| `bf_endian_f64_verify.mlir` | Verify f64 BE vs LE byte order |

---

### 14. Integration Tests (3 tests)

| Test File | Description |
|-----------|-------------|
| `bf_integration_packet.mlir` | Encode/decode full packet structure |
| `bf_integration_length_prefix.mlir` | Length-prefixed string roundtrip |
| `bf_integration_count_prefix.mlir` | Count-prefixed list roundtrip |

---

## Summary

**Total: 84 test cases**

## Test Template

```mlir
// RUN: %ecoc %s -emit=jit 2>&1 | %FileCheck %s
//
// Test description here

module {
  func.func @main() -> i64 {
    // Test body

    %zero = arith.constant 0 : i64
    return %zero : i64
  }
}
```

## bf Dialect Operations Reference

### Encoder Operations
- `bf.alloc %size : i32 -> !eco.value` - Allocate ByteBuffer
- `bf.cursor.init %buffer : !eco.value -> !bf.cur` - Create cursor
- `bf.write.u8 %cur, %val : !bf.cur, i64 -> !bf.cur`
- `bf.write.u16_be/le %cur, %val : !bf.cur, i64 -> !bf.cur`
- `bf.write.u32_be/le %cur, %val : !bf.cur, i64 -> !bf.cur`
- `bf.write.f32_be/le %cur, %val : !bf.cur, f64 -> !bf.cur`
- `bf.write.f64_be/le %cur, %val : !bf.cur, f64 -> !bf.cur`
- `bf.write.bytes_copy %cur, %bytes : !bf.cur, !eco.value -> !bf.cur`
- `bf.write.utf8 %cur, %string : !bf.cur, !eco.value -> !bf.cur`

### Decoder Operations
- `bf.require %cur, %bytes : !bf.cur, i32 -> i1` - Bounds check
- `bf.read.u8 %cur : !bf.cur -> (i64, !bf.cur)`
- `bf.read.i8 %cur : !bf.cur -> (i64, !bf.cur)`
- `bf.read.u16_be/le %cur : !bf.cur -> (i64, !bf.cur)`
- `bf.read.i16_be/le %cur : !bf.cur -> (i64, !bf.cur)`
- `bf.read.u32_be/le %cur : !bf.cur -> (i64, !bf.cur)`
- `bf.read.i32_be/le %cur : !bf.cur -> (i64, !bf.cur)`
- `bf.read.f32_be/le %cur : !bf.cur -> (f64, !bf.cur)`
- `bf_read.f64_be/le %cur : !bf.cur -> (f64, !bf.cur)`
- `bf.read.bytes %cur, %len : !bf.cur, i32 -> (!eco.value, !bf.cur)`
- `bf.read.utf8 %cur, %len : !bf.cur, i32 -> (!eco.value, !bf.cur)`

### Types
- `!bf.cur` - Cursor type (lowered to `{i8*, i8*}` by BFToLLVM)
- `!eco.value` - Elm heap value (ByteBuffer, String, etc.)
