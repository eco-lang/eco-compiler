//===- BFOps.td - ByteFusion dialect operations -------------------*- tablegen -*-===//
//
// MLIR ODS definitions for the BF (ByteFusion) dialect operations.
//
// The BF dialect represents fused byte encoding/decoding operations for
// Elm's Bytes.Encode and Bytes.Decode modules. It captures cursor-based
// byte operations in a form amenable to efficient lowering to LLVM IR.
//
//===----------------------------------------------------------------------===//

include "mlir/IR/OpBase.td"
include "mlir/IR/EnumAttr.td"
include "mlir/Interfaces/SideEffectInterfaces.td"

//===----------------------------------------------------------------------===//
// Type Constraints for Eco interop
//===----------------------------------------------------------------------===//


//===----------------------------------------------------------------------===//
// Dialect Definition
//===----------------------------------------------------------------------===//

def BF_Dialect : Dialect {
  let name = "bf";
  let cppNamespace = "::bf";
  let summary = "ByteFusion dialect for fused Elm byte encoding/decoding";
  let description = [{
    The BF dialect represents fused byte encoding/decoding operations for
    Elm's Bytes.Encode and Bytes.Decode modules. It captures cursor-based
    byte operations that are lowered to efficient LLVM IR.

    Key design decisions:
    - `bf.cursor` is a paired pointer (ptr, end) for bounds checking
    - Write operations consume cursor, return new cursor (SSA threading)
    - Integrates with eco.value for Elm heap objects
    - Runtime helpers handle layout details (no GEPs into headers)
  }];
  let useDefaultTypePrinterParser = 1;
}

//===----------------------------------------------------------------------===//
// Type Definitions
//===----------------------------------------------------------------------===//

class BF_Type<string name, string typeMnemonic, list<Trait> traits = []>
    : TypeDef<BF_Dialect, name, traits> {
  let mnemonic = typeMnemonic;
}

def BF_CursorType : BF_Type<"Cursor", "cursor"> {
  let summary = "BF cursor type for byte buffer traversal";
  let description = [{
    A cursor into a byte buffer, represented as a pair of pointers:
    (current_ptr, end_ptr). Write operations advance current_ptr
    and return a new cursor. Read operations advance and check bounds.

    During lowering, this becomes `{ i8*, i8* }` in LLVM IR.
  }];
  let builderCall = "$_builder.getType<bf::CursorType>()";
}

//===----------------------------------------------------------------------===//
// Type Constraints
//===----------------------------------------------------------------------===//

def BF_Cursor : Type<CPred<"llvm::isa<bf::CursorType>($_self)">,
                     "bf.cursor",
                     "bf::CursorType">,
                     BuildableType<"$_builder.getType<bf::CursorType>()">;

//===----------------------------------------------------------------------===//
// Endianness Attribute
//===----------------------------------------------------------------------===//

def BF_Endianness : I32EnumAttr<"Endianness", "Byte order", [
  I32EnumAttrCase<"LE", 0, "le">,  // Little-endian
  I32EnumAttrCase<"BE", 1, "be">   // Big-endian
]> {
  let cppNamespace = "::bf";
}

//===----------------------------------------------------------------------===//
// Base Op Class
//===----------------------------------------------------------------------===//

class BF_Op<string mnemonic, list<Trait> traits = []>
    : Op<BF_Dialect, mnemonic, traits>;

//===----------------------------------------------------------------------===//
// Buffer Allocation
//===----------------------------------------------------------------------===//

def BF_AllocOp : BF_Op<"alloc", [MemoryEffects<[MemWrite]>]> {
  let summary = "Allocate a ByteBuffer of given size";
  let description = [{
    Allocates a ByteBuffer with the specified number of bytes.
    Returns an eco.value (heap pointer) to the allocated ByteBuffer.

    This calls the runtime helper elm_alloc_bytebuffer(size).
  }];

  let arguments = (ins I32:$size);
  let results = (outs AnyType:$buffer);

  let assemblyFormat = "$size attr-dict `:` type($buffer)";
}

//===----------------------------------------------------------------------===//
// Cursor Operations
//===----------------------------------------------------------------------===//

def BF_CursorInitOp : BF_Op<"cursor.init", []> {
  let summary = "Initialize a cursor from a ByteBuffer for encoding";
  let description = [{
    Creates a cursor pointing to the start of a ByteBuffer.
    The buffer argument is an eco.value (heap pointer to ByteBuffer).

    This calls elm_bytebuffer_data(buffer) to get the data pointer
    and elm_bytebuffer_len(buffer) to compute the end pointer.
  }];

  let arguments = (ins AnyType:$buffer);
  let results = (outs BF_Cursor:$cursor);

  let assemblyFormat = "$buffer attr-dict `:` type($buffer) `->` type($cursor)";
}

def BF_CursorPtrOp : BF_Op<"cursor.ptr", [Pure]> {
  let summary = "Extract the current pointer from a cursor";
  let description = [{
    Returns the current byte pointer from the cursor.
    Used for getting the raw pointer to the buffer data.
  }];

  let arguments = (ins BF_Cursor:$cursor);
  let results = (outs I64:$ptr);  // Raw pointer as i64

  let assemblyFormat = "$cursor attr-dict `:` type($ptr)";
}

//===----------------------------------------------------------------------===//
// Write Operations (Encoder)
//===----------------------------------------------------------------------===//

def BF_WriteU8Op : BF_Op<"write.u8", [MemoryEffects<[MemWrite]>]> {
  let summary = "Write an unsigned 8-bit integer";
  let description = [{
    Writes the low 8 bits of the value to the cursor position.
    Returns a new cursor with advanced position.
  }];

  let arguments = (ins BF_Cursor:$cursor, I64:$value);
  let results = (outs BF_Cursor:$result);

  let assemblyFormat = "$cursor `,` $value attr-dict `:` type($result)";
}

def BF_WriteU16Op : BF_Op<"write.u16", [MemoryEffects<[MemWrite]>]> {
  let summary = "Write an unsigned 16-bit integer";
  let description = [{
    Writes the low 16 bits of the value to the cursor position.
    Byte order is determined by the endianness attribute.
    Returns a new cursor with advanced position.
  }];

  let arguments = (ins BF_Cursor:$cursor, I64:$value, BF_Endianness:$endianness);
  let results = (outs BF_Cursor:$result);

  let assemblyFormat = "$cursor `,` $value `(` $endianness `)` attr-dict `:` type($result)";
}

def BF_WriteU32Op : BF_Op<"write.u32", [MemoryEffects<[MemWrite]>]> {
  let summary = "Write an unsigned 32-bit integer";
  let description = [{
    Writes the low 32 bits of the value to the cursor position.
    Byte order is determined by the endianness attribute.
    Returns a new cursor with advanced position.
  }];

  let arguments = (ins BF_Cursor:$cursor, I64:$value, BF_Endianness:$endianness);
  let results = (outs BF_Cursor:$result);

  let assemblyFormat = "$cursor `,` $value `(` $endianness `)` attr-dict `:` type($result)";
}

def BF_WriteF32Op : BF_Op<"write.f32", [MemoryEffects<[MemWrite]>]> {
  let summary = "Write a 32-bit float";
  let description = [{
    Casts f64 to f32 and writes 4 bytes to the cursor position.
    Byte order is determined by the endianness attribute.
    Returns a new cursor with advanced position.
  }];

  let arguments = (ins BF_Cursor:$cursor, F64:$value, BF_Endianness:$endianness);
  let results = (outs BF_Cursor:$result);

  let assemblyFormat = "$cursor `,` $value `(` $endianness `)` attr-dict `:` type($result)";
}

def BF_WriteF64Op : BF_Op<"write.f64", [MemoryEffects<[MemWrite]>]> {
  let summary = "Write a 64-bit float";
  let description = [{
    Writes 8 bytes of f64 to the cursor position.
    Byte order is determined by the endianness attribute.
    Returns a new cursor with advanced position.
  }];

  let arguments = (ins BF_Cursor:$cursor, F64:$value, BF_Endianness:$endianness);
  let results = (outs BF_Cursor:$result);

  let assemblyFormat = "$cursor `,` $value `(` $endianness `)` attr-dict `:` type($result)";
}

def BF_WriteBytesOp : BF_Op<"write.bytes", [MemoryEffects<[MemRead, MemWrite]>]> {
  let summary = "Copy bytes from a ByteBuffer";
  let description = [{
    Copies all bytes from the source ByteBuffer to the cursor position.
    The source is an eco.value (i64) representing a ByteBuffer.
    Returns a new cursor with advanced position.
  }];

  let arguments = (ins BF_Cursor:$cursor, AnyType:$bytes);
  let results = (outs BF_Cursor:$result);

  let assemblyFormat = "$cursor `,` $bytes attr-dict `:` `(` type($bytes) `)` `->` type($result)";
}

def BF_WriteUtf8Op : BF_Op<"write.utf8", [MemoryEffects<[MemRead, MemWrite]>]> {
  let summary = "Write string as UTF-8 bytes";
  let description = [{
    Encodes an ElmString as UTF-8 and writes to the cursor position.
    The string is an eco.value (i64) representing an ElmString.
    Returns a new cursor with advanced position.

    This calls elm_utf8_copy(string, cursor.ptr) internally.
  }];

  let arguments = (ins BF_Cursor:$cursor, AnyType:$string);
  let results = (outs BF_Cursor:$result);

  let assemblyFormat = "$cursor `,` $string attr-dict `:` `(` type($string) `)` `->` type($result)";
}

//===----------------------------------------------------------------------===//
// Width Computation Operations
//===----------------------------------------------------------------------===//

def BF_Utf8WidthOp : BF_Op<"utf8_width", [MemoryEffects<[MemRead]>]> {
  let summary = "Compute UTF-8 byte width of a string";
  let description = [{
    Returns the number of bytes needed to encode the string as UTF-8.
    The string is an eco.value (i64) representing an ElmString.

    This calls elm_utf8_width(string) internally.
  }];

  let arguments = (ins AnyType:$string);
  let results = (outs I32:$width);

  let assemblyFormat = "$string attr-dict `:` type($string) `->` type($width)";
}

def BF_BytesWidthOp : BF_Op<"bytes_width", [MemoryEffects<[MemRead]>]> {
  let summary = "Get byte length of a ByteBuffer";
  let description = [{
    Returns the number of bytes in the ByteBuffer.
    The buffer is an eco.value (i64) representing a ByteBuffer.

    This calls elm_bytebuffer_len(buffer) internally.
  }];

  let arguments = (ins AnyType:$buffer);
  let results = (outs I32:$width);

  let assemblyFormat = "$buffer attr-dict `:` type($buffer) `->` type($width)";
}

//===----------------------------------------------------------------------===//
// Read Operations (Decoder) - Phase 2
//===----------------------------------------------------------------------===//

def BF_RequireOp : BF_Op<"require", []> {
  let summary = "Check if cursor has enough bytes remaining";
  let description = [{
    Bounds check for decoder operations.
    Returns true if cursor has at least 'bytes' remaining.
    Used in scf.if for fail-fast pattern.
  }];

  let arguments = (ins BF_Cursor:$cursor, I32:$bytes);
  let results = (outs I1:$ok);

  let assemblyFormat = "$cursor `,` $bytes attr-dict `:` type($ok)";
}

//===----------------------------------------------------------------------===//
// Scalar Read Operations (Decoder)
//===----------------------------------------------------------------------===//
//
// Safety model: Caller MUST emit bf.require + fail-fast control flow BEFORE
// calling these read ops. The read ops perform unconditional loads - safe
// because bounds have already been verified by bf.require.
//
// Return values use Elm-level types:
// - Integer reads (u8/i8/u16/i16/u32/i32) return i64 (Elm Int representation)
// - Float reads (f32/f64) return f64 (Elm Float representation)

def BF_ReadU8Op : BF_Op<"read.u8", []> {
  let summary = "Read unsigned 8-bit integer";
  let description = [{
    Reads 1 byte and zero-extends to i64 (Elm Int).
    Advances cursor by 1 byte.
    SAFETY: Caller must ensure bounds via bf.require before this op.
  }];

  let arguments = (ins BF_Cursor:$cursor);
  let results = (outs I64:$value, BF_Cursor:$newCursor);

  let assemblyFormat = "$cursor attr-dict `:` type($value) `,` type($newCursor)";
}

def BF_ReadI8Op : BF_Op<"read.i8", []> {
  let summary = "Read signed 8-bit integer";
  let description = [{
    Reads 1 byte and sign-extends to i64 (Elm Int).
    Advances cursor by 1 byte.
    SAFETY: Caller must ensure bounds via bf.require before this op.
  }];

  let arguments = (ins BF_Cursor:$cursor);
  let results = (outs I64:$value, BF_Cursor:$newCursor);

  let assemblyFormat = "$cursor attr-dict `:` type($value) `,` type($newCursor)";
}

def BF_ReadU16Op : BF_Op<"read.u16", []> {
  let summary = "Read unsigned 16-bit integer";
  let description = [{
    Reads 2 bytes with specified endianness and zero-extends to i64 (Elm Int).
    Advances cursor by 2 bytes.
    SAFETY: Caller must ensure bounds via bf.require before this op.
  }];

  let arguments = (ins BF_Cursor:$cursor, BF_Endianness:$endianness);
  let results = (outs I64:$value, BF_Cursor:$newCursor);

  let assemblyFormat = "$cursor `(` $endianness `)` attr-dict `:` type($value) `,` type($newCursor)";
}

def BF_ReadI16Op : BF_Op<"read.i16", []> {
  let summary = "Read signed 16-bit integer";
  let description = [{
    Reads 2 bytes with specified endianness and sign-extends to i64 (Elm Int).
    Advances cursor by 2 bytes.
    SAFETY: Caller must ensure bounds via bf.require before this op.
  }];

  let arguments = (ins BF_Cursor:$cursor, BF_Endianness:$endianness);
  let results = (outs I64:$value, BF_Cursor:$newCursor);

  let assemblyFormat = "$cursor `(` $endianness `)` attr-dict `:` type($value) `,` type($newCursor)";
}

def BF_ReadU32Op : BF_Op<"read.u32", []> {
  let summary = "Read unsigned 32-bit integer";
  let description = [{
    Reads 4 bytes with specified endianness and zero-extends to i64 (Elm Int).
    Advances cursor by 4 bytes.
    SAFETY: Caller must ensure bounds via bf.require before this op.
  }];

  let arguments = (ins BF_Cursor:$cursor, BF_Endianness:$endianness);
  let results = (outs I64:$value, BF_Cursor:$newCursor);

  let assemblyFormat = "$cursor `(` $endianness `)` attr-dict `:` type($value) `,` type($newCursor)";
}

def BF_ReadI32Op : BF_Op<"read.i32", []> {
  let summary = "Read signed 32-bit integer";
  let description = [{
    Reads 4 bytes with specified endianness and sign-extends to i64 (Elm Int).
    Advances cursor by 4 bytes.
    SAFETY: Caller must ensure bounds via bf.require before this op.
  }];

  let arguments = (ins BF_Cursor:$cursor, BF_Endianness:$endianness);
  let results = (outs I64:$value, BF_Cursor:$newCursor);

  let assemblyFormat = "$cursor `(` $endianness `)` attr-dict `:` type($value) `,` type($newCursor)";
}

def BF_ReadF32Op : BF_Op<"read.f32", []> {
  let summary = "Read 32-bit float";
  let description = [{
    Reads 4 bytes with specified endianness, interprets as float32,
    and extends to f64 (Elm Float).
    Advances cursor by 4 bytes.
    SAFETY: Caller must ensure bounds via bf.require before this op.
  }];

  let arguments = (ins BF_Cursor:$cursor, BF_Endianness:$endianness);
  let results = (outs F64:$value, BF_Cursor:$newCursor);

  let assemblyFormat = "$cursor `(` $endianness `)` attr-dict `:` type($value) `,` type($newCursor)";
}

def BF_ReadF64Op : BF_Op<"read.f64", []> {
  let summary = "Read 64-bit float";
  let description = [{
    Reads 8 bytes with specified endianness and interprets as f64 (Elm Float).
    Advances cursor by 8 bytes.
    SAFETY: Caller must ensure bounds via bf.require before this op.
  }];

  let arguments = (ins BF_Cursor:$cursor, BF_Endianness:$endianness);
  let results = (outs F64:$value, BF_Cursor:$newCursor);

  let assemblyFormat = "$cursor `(` $endianness `)` attr-dict `:` type($value) `,` type($newCursor)";
}

//===----------------------------------------------------------------------===//
// Heap Read Operations (Decoder)
//===----------------------------------------------------------------------===//
//
// These ops read variable-length data into Elm heap objects.
// - BOUNDS safety: Caller must ensure via bf.require before calling.
// - ok flag: Indicates non-bounds failure (e.g., invalid UTF-8).

def BF_ReadBytesOp : BF_Op<"read.bytes", [MemoryEffects<[MemRead, MemWrite]>]> {
  let summary = "Read bytes into a new ByteBuffer";
  let description = [{
    Reads 'len' bytes into a newly allocated ByteBuffer.
    Returns the ByteBuffer as eco.value (i64).
    Advances cursor by 'len' bytes.
    ok is true on success (allocation succeeded).
    SAFETY: Caller must ensure bounds via bf.require before this op.
  }];

  let arguments = (ins BF_Cursor:$cursor, I32:$len);
  let results = (outs AnyType:$bytes, BF_Cursor:$newCursor, I1:$ok);

  let assemblyFormat = "$cursor `,` $len attr-dict `:` type($bytes) `,` type($newCursor) `,` type($ok)";
}

def BF_ReadUtf8Op : BF_Op<"read.utf8", [MemoryEffects<[MemRead, MemWrite]>]> {
  let summary = "Decode bytes as UTF-8 string";
  let description = [{
    Reads 'len' bytes and decodes them as UTF-8 into an ElmString.
    Returns the string as eco.value (i64).
    Advances cursor by 'len' bytes.
    ok is true if UTF-8 decoding succeeded (valid UTF-8).
    SAFETY: Caller must ensure bounds via bf.require before this op.
  }];

  let arguments = (ins BF_Cursor:$cursor, I32:$len);
  let results = (outs AnyType:$string, BF_Cursor:$newCursor, I1:$ok);

  let assemblyFormat = "$cursor `,` $len attr-dict `:` type($string) `,` type($newCursor) `,` type($ok)";
}

//===----------------------------------------------------------------------===//
// Cursor Init for Decoder
//===----------------------------------------------------------------------===//

def BF_DecoderCursorInitOp : BF_Op<"decoder.cursor.init", []> {
  let summary = "Initialize cursor from Bytes for decoding";
  let description = [{
    Creates a cursor for decoding from a Bytes (ByteBuffer) value.
    The bytes argument can be an eco.value or i64 depending on
    whether it's already been unwrapped.
    This is the decoder counterpart to bf.cursor.init.
  }];

  let arguments = (ins AnyType:$bytes);
  let results = (outs BF_Cursor:$cursor);

  let assemblyFormat = "$bytes attr-dict `:` type($bytes) `->` type($cursor)";
}
