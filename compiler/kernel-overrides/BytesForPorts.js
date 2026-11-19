/*
kind kernel
requires Elm.Kernel.Json
package elm/json 1.1.4
*/
// Lets ports carry `Bytes`: the decoder accepts a `Uint8Array`, an `ArrayBuffer` or a `DataView` and
// gives a `DataView`; the encoder gives a `Uint8Array` over the same bytes. A Bytes port refers to them
// as the Json kernel's `decodeBytes` and `encodeBytes` (Compiler.LocalOpt.Erased.Port), which elm/json's
// own kernel does not define. `_Json_decodePrim`, `_Json_expecting` and `_Json_wrap` are
// identical in elm/json 1.1.0-1.1.4 (plans/js-kernel-overrides.md, Risks).
var _Json_decodeBytes = _Json_decodePrim(function(value) {
    if (value instanceof Uint8Array) {
        return $elm$core$Result$Ok(new DataView(value.buffer, value.byteOffset, value.byteLength));
    }
    if (value instanceof ArrayBuffer) {
        return $elm$core$Result$Ok(new DataView(value));
    }
    if (value instanceof DataView) {
        return $elm$core$Result$Ok(value);
    }
    return _Json_expecting('a BYTES value (Uint8Array, ArrayBuffer, or DataView)', value);
});

var _Json_encodeBytes = function(bytes) {
    return _Json_wrap(new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.byteLength));
};
