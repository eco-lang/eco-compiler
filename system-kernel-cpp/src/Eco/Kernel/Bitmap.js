/*

*/

// Bitmap.popCount32 and Bitmap.index for the JavaScript backend: the classic parallel bit count over
// the low 32 bits (JavaScript's bitwise operators already work on 32 bits). The native kernel is
// src/eco-system/Bitmap/BitmapExports.cpp; both give the same numbers for every input.

var _Bitmap_popCount32 = function (x) {
    x = x - ((x >>> 1) & 0x55555555);
    x = (x & 0x33333333) + ((x >>> 2) & 0x33333333);
    return Math.imul((x + (x >>> 4)) & 0x0F0F0F0F, 0x01010101) >>> 24;
};

// (1 << 31) - 1 is -2147483649, which `&` reads as 0x7FFFFFFF; `i & 31` reduces a negative i mod 32.
var _Bitmap_index = F2(function (bitmap, i) {
    return _Bitmap_popCount32(bitmap & ((1 << (i & 31)) - 1));
});
