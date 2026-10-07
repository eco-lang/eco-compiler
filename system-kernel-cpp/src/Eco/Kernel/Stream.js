/*
import Eco.Kernel.Scheduler exposing (binding)
*/

// Stream — JS twin of src/eco-system/Stream/ (eco/system).
// The JS target is not supported yet (plans/eco-system-library.md §1, Phase 10): every
// function throws when called. Zero-argument Task values throw only when the Task runs.

function _Stream_unsupported(name) {
    throw new Error('eco/system: Stream.' + name + ' is not supported on the JS target yet');
}

var _Stream_identity = F2(function(a0, a1) { _Stream_unsupported('identity'); });
var _Stream_custom = F4(function(a0, a1, a2, a3) { _Stream_unsupported('custom'); });
var _Stream_read = function(a0) { _Stream_unsupported('read'); };
var _Stream_write = F2(function(a0, a1) { _Stream_unsupported('write'); });
var _Stream_enqueue = F2(function(a0, a1) { _Stream_unsupported('enqueue'); });
var _Stream_closeWritable = function(a0) { _Stream_unsupported('closeWritable'); };
var _Stream_cancelReadable = F2(function(a0, a1) { _Stream_unsupported('cancelReadable'); });
var _Stream_cancelWritable = F2(function(a0, a1) { _Stream_unsupported('cancelWritable'); });
var _Stream_pipeThrough = F2(function(a0, a1) { _Stream_unsupported('pipeThrough'); });
var _Stream_pipeTo = F2(function(a0, a1) { _Stream_unsupported('pipeTo'); });
var _Stream_textEncoder = __Scheduler_binding(function() { _Stream_unsupported('textEncoder'); });
var _Stream_textDecoder = __Scheduler_binding(function() { _Stream_unsupported('textDecoder'); });
var _Stream_compressor = function(a0) { _Stream_unsupported('compressor'); };
var _Stream_decompressor = function(a0) { _Stream_unsupported('decompressor'); };
var _Stream_utf8ToString = function(a0) { _Stream_unsupported('utf8ToString'); };
var _Stream_stringToUtf8 = function(a0) { _Stream_unsupported('stringToUtf8'); };
