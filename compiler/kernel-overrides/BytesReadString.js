/*
kind kernel
requires Elm.Kernel.Bytes
requires Elm.Kernel.Utils
package elm/bytes 1.0.8
*/
// elm/bytes builds a decoded String with `+=`, one character at a time. V8 keeps such a chain of
// concatenated strings alive as a tree of pieces, and decoding large Strings (package caches, elm-css)
// runs out of memory (guida issue 107). This builds an array and joins it once. Same contract:
// (len, bytes, offset) -> ( offset after the String, the String ). The stock function is identical in
// elm/bytes 1.0.0-1.0.8 (plans/js-kernel-overrides.md, Risks).
_Bytes_read_string = F3(function(len, bytes, offset)
{
	var string = [];
	var end = offset + len;
	for (; offset < end;)
	{
		var byte = bytes.getUint8(offset++);
		string.push(
			(byte < 128)
				? String.fromCharCode(byte)
				:
			((byte & 0xE0 /* 0b11100000 */) === 0xC0 /* 0b11000000 */)
				? String.fromCharCode((byte & 0x1F /* 0b00011111 */) << 6 | bytes.getUint8(offset++) & 0x3F /* 0b00111111 */)
				:
			((byte & 0xF0 /* 0b11110000 */) === 0xE0 /* 0b11100000 */)
				? String.fromCharCode(
					(byte & 0xF /* 0b00001111 */) << 12
					| (bytes.getUint8(offset++) & 0x3F /* 0b00111111 */) << 6
					| bytes.getUint8(offset++) & 0x3F /* 0b00111111 */
				)
				:
				(byte =
					((byte & 0x7 /* 0b00000111 */) << 18
						| (bytes.getUint8(offset++) & 0x3F /* 0b00111111 */) << 12
						| (bytes.getUint8(offset++) & 0x3F /* 0b00111111 */) << 6
						| bytes.getUint8(offset++) & 0x3F /* 0b00111111 */
					) - 0x10000
				, String.fromCharCode(Math.floor(byte / 0x400) + 0xD800, byte % 0x400 + 0xDC00)
				)
		);
	}
	return _Utils_Tuple2(offset, string.join(''));
});
