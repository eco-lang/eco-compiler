/*
*/

// Hash — native string hashing.
//
// The JS twin of eco-kernel/Hash.cpp, used by the JS bootstrap stages. The mix must
// match the C++ and the pure-Elm twins exactly, so all three agree bit for
// bit: base 2^26 keeps every intermediate inside the exact-integer range of a
// JS double (h < 2^26, so h * 33 < 2^31).

var _Hash_stringWithSeed = F2(function(seed, str) {
    var h = seed % 67108864;
    for (var i = 0; i < str.length; i++) {
        h = (h * 33 + (str.charCodeAt(i) % 67108864) + 7) % 67108864;
    }
    return h;
});

// The wide variant. JS has no 64-bit integers, so this is NOT the same value
// the native kernel computes -- deliberately. Nothing compares hashes across
// builds: `Data.HashMap` never serializes, and a hash only chooses a bucket.
// 2^31 keeps every intermediate exact in a double.
var _Hash_string64 = F2(function(seed, str) {
    var h = (seed ^ 2166136261) % 2147483648;
    for (var i = 0; i < str.length; i++) {
        h = (h ^ str.charCodeAt(i)) % 2147483648;
        h = (h * 16777619) % 2147483648;
    }
    return h;
});
