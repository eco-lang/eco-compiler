/*
kind value
value $author$project$Eco$MVar$stash
group mvar-stash
*/
// Stage 1 only (guida.js, from compiler/src-xhr/Eco/MVar.elm): MVar values stay JavaScript objects in
// bin/eco-io-handler.js (globalThis.__ecoMVarStash), so put, read and take send a 12-byte token instead of
// encoding and decoding the value. The three mvar-stash overrides apply together or not at all.
// `stash`: what put sends for a value: its token.
var $author$project$Eco$MVar$stash = F2(
	function (encoder, value) {
		return globalThis.__ecoMVarStash.stash(value);
	});
