/*
kind value
value $author$project$Eco$MVar$unstashing
group mvar-stash
*/
// Stage 1 only (guida.js, from compiler/src-xhr/Eco/MVar.elm): MVar values stay JavaScript objects in
// bin/eco-io-handler.js (globalThis.__ecoMVarStash), so put, read and take send a 12-byte token instead of
// encoding and decoding the value. The three mvar-stash overrides apply together or not at all.
// `unstashing`, the decoder read uses: it returns the stashed value a token stands for and leaves it stashed;
// anything else is read with the given decoder.
var $author$project$Eco$MVar$unstashing = function (decoder) {
	return $elm$bytes$Bytes$Decode$Decoder(F2(function (bytes, offset) {
		var hit = globalThis.__ecoMVarStash.unstash(bytes, offset, false);
		return hit ? _Utils_Tuple2(offset + hit.width, hit.value) : A2(decoder.a, bytes, offset);
	}));
};
