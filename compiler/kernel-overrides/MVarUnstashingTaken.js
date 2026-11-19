/*
kind value
value $author$project$Eco$MVar$unstashingTaken
group mvar-stash
*/
// Stage 1 only (guida.js, from compiler/src-xhr/Eco/MVar.elm): MVar values stay JavaScript objects in
// bin/eco-io-handler.js (globalThis.__ecoMVarStash), so put, read and take send a 12-byte token instead of
// encoding and decoding the value. The three mvar-stash overrides apply together or not at all.
// `unstashingTaken`, the decoder take uses: it returns the stashed value a token stands for and releases it;
// anything else is read with the given decoder.
var $author$project$Eco$MVar$unstashingTaken = function (decoder) {
	return $elm$bytes$Bytes$Decode$Decoder(F2(function (bytes, offset) {
		var hit = globalThis.__ecoMVarStash.unstash(bytes, offset, true);
		return hit ? _Utils_Tuple2(offset + hit.width, hit.value) : A2(decoder.a, bytes, offset);
	}));
};
