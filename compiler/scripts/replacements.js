#!/usr/bin/env node

const fs = require('node:fs');

const argv = process.argv.slice(2);
const path = argv[0];

const data = fs
    .readFileSync(path, { encoding: 'utf8', flag: 'r' })

    /* Prevents V8 from retaining large "concatenated string" chains, which can cause OOMs.
       Tested against `rtfeldman/elm-css` compilation.
    
       See the related discussion for context: https://discourse.elm-lang.org/t/guida-compiler-was-there-are-3-elm-compilers-written-in-elm/10329/34
       and issue: https://github.com/guida-lang/compiler/issues/107
     */
    .replace(`var _Bytes_read_string = F3(function(len, bytes, offset)
{
\tvar string = '';
\tvar end = offset + len;
\tfor (; offset < end;)
\t{
\t\tvar byte = bytes.getUint8(offset++);
\t\tstring +=
\t\t\t(byte < 128)
\t\t\t\t? String.fromCharCode(byte)
\t\t\t\t:
\t\t\t((byte & 0xE0 /* 0b11100000 */) === 0xC0 /* 0b11000000 */)
\t\t\t\t? String.fromCharCode((byte & 0x1F /* 0b00011111 */) << 6 | bytes.getUint8(offset++) & 0x3F /* 0b00111111 */)
\t\t\t\t:
\t\t\t((byte & 0xF0 /* 0b11110000 */) === 0xE0 /* 0b11100000 */)
\t\t\t\t? String.fromCharCode(
\t\t\t\t\t(byte & 0xF /* 0b00001111 */) << 12
\t\t\t\t\t| (bytes.getUint8(offset++) & 0x3F /* 0b00111111 */) << 6
\t\t\t\t\t| bytes.getUint8(offset++) & 0x3F /* 0b00111111 */
\t\t\t\t)
\t\t\t\t:
\t\t\t\t(byte =
\t\t\t\t\t((byte & 0x7 /* 0b00000111 */) << 18
\t\t\t\t\t\t| (bytes.getUint8(offset++) & 0x3F /* 0b00111111 */) << 12
\t\t\t\t\t\t| (bytes.getUint8(offset++) & 0x3F /* 0b00111111 */) << 6
\t\t\t\t\t\t| bytes.getUint8(offset++) & 0x3F /* 0b00111111 */
\t\t\t\t\t) - 0x10000
\t\t\t\t, String.fromCharCode(Math.floor(byte / 0x400) + 0xD800, byte % 0x400 + 0xDC00)
\t\t\t\t);
\t}
\treturn _Utils_Tuple2(offset, string);
});`, `var _Bytes_read_string = F3(function(len, bytes, offset)
{
\tvar string = [];
\tvar end = offset + len;
\tfor (; offset < end;)
\t{
\t\tvar byte = bytes.getUint8(offset++);
\t\tstring.push(
\t\t\t(byte < 128)
\t\t\t\t? String.fromCharCode(byte)
\t\t\t\t:
\t\t\t((byte & 0xE0 /* 0b11100000 */) === 0xC0 /* 0b11000000 */)
\t\t\t\t? String.fromCharCode((byte & 0x1F /* 0b00011111 */) << 6 | bytes.getUint8(offset++) & 0x3F /* 0b00111111 */)
\t\t\t\t:
\t\t\t((byte & 0xF0 /* 0b11110000 */) === 0xE0 /* 0b11100000 */)
\t\t\t\t? String.fromCharCode(
\t\t\t\t\t(byte & 0xF /* 0b00001111 */) << 12
\t\t\t\t\t| (bytes.getUint8(offset++) & 0x3F /* 0b00111111 */) << 6
\t\t\t\t\t| bytes.getUint8(offset++) & 0x3F /* 0b00111111 */
\t\t\t\t)
\t\t\t\t:
\t\t\t\t(byte =
\t\t\t\t\t((byte & 0x7 /* 0b00000111 */) << 18
\t\t\t\t\t\t| (bytes.getUint8(offset++) & 0x3F /* 0b00111111 */) << 12
\t\t\t\t\t\t| (bytes.getUint8(offset++) & 0x3F /* 0b00111111 */) << 6
\t\t\t\t\t\t| bytes.getUint8(offset++) & 0x3F /* 0b00111111 */
\t\t\t\t\t) - 0x10000
\t\t\t\t, String.fromCharCode(Math.floor(byte / 0x400) + 0xD800, byte % 0x400 + 0xDC00)
\t\t\t\t)
\t\t);
\t}
\treturn _Utils_Tuple2(offset, string.join(''));
});`)

    /* Add Bytes encoder/decoder for ports support.
       Allows Bytes.Bytes to be sent through ports, mapping to Uint8Array on the JS side.
     */
    .replace(
        `var _Json_encodeNull = _Json_wrap(null);`,
        `var _Json_encodeNull = _Json_wrap(null);

// BYTES FOR PORTS
var _Json_decodeBytes = _Json_decodePrim(function(value) {
\tif (value instanceof Uint8Array) {
\t\treturn $elm$core$Result$Ok(new DataView(value.buffer, value.byteOffset, value.byteLength));
\t}
\tif (value instanceof ArrayBuffer) {
\t\treturn $elm$core$Result$Ok(new DataView(value));
\t}
\tif (value instanceof DataView) {
\t\treturn $elm$core$Result$Ok(value);
\t}
\treturn _Json_expecting('a BYTES value (Uint8Array, ArrayBuffer, or DataView)', value);
});

var _Json_encodeBytes = function(bytes) {
\treturn _Json_wrap(new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.byteLength));
};`
    );

/* MVar values stay JavaScript objects (src-xhr/Eco/MVar.elm, "STASH"): `put` sends eco-io a
   token from bin/eco-io-handler.js's stash instead of the encoded value, and `read` and `take`
   return the stashed object instead of decoding bytes, as the native MVar does. Each definition is
   replaced whole. */
function replaceDefinition(source, name, replacement) {
    const re = new RegExp('^var \\$author\\$project\\$Eco\\$MVar\\$' + name + ' = [\\s\\S]*?\\n(?=var )', 'gm');
    const matches = source.match(re) || [];
    if (matches.length !== 1) {
        throw new Error(`replacements.js: expected one definition of Eco.MVar.${name}, found ${matches.length}`);
    }
    return source.replace(re, () => replacement);
}

const unstashingDefinition = (name, taken) => `var $author$project$Eco$MVar$${name} = function (decoder) {
\treturn $elm$bytes$Bytes$Decode$Decoder(F2(function (bytes, offset) {
\t\tvar hit = globalThis.__ecoMVarStash.unstash(bytes, offset, ${taken});
\t\treturn hit ? _Utils_Tuple2(offset + hit.width, hit.value) : A2(decoder.a, bytes, offset);
\t}));
};
`;

// Only outputs built from src-xhr have these hooks; eco-boot.js (the kernel build) has a native-style
// MVar and none of them, and is left as it is. Some but not all of them means the hooks drifted.
const stashHooks = ['stash', 'unstashing', 'unstashingTaken'].filter((name) =>
    new RegExp('^var \\$author\\$project\\$Eco\\$MVar\\$' + name + ' = ', 'm').test(data));
if (stashHooks.length !== 0 && stashHooks.length !== 3) {
    throw new Error(`replacements.js: only some Eco.MVar stash hooks found: ${stashHooks.join(', ')}`);
}

let patched = data;
if (stashHooks.length === 3) {
patched = replaceDefinition(patched, 'stash', `var $author$project$Eco$MVar$stash = F2(
\tfunction (encoder, value) {
\t\treturn globalThis.__ecoMVarStash.stash(value);
\t});
`);
patched = replaceDefinition(patched, 'unstashing', unstashingDefinition('unstashing', false));
patched = replaceDefinition(patched, 'unstashingTaken', unstashingDefinition('unstashingTaken', true));
}

fs.writeFileSync(path, patched, { encoding: 'utf8', flag: 'w' });