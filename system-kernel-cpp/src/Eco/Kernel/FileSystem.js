/*
import Eco.Kernel.Scheduler exposing (binding)
*/

// FileSystem — JS twin of src/eco-system/FileSystem/ (eco/system).
// The JS target is not supported yet (plans/eco-system-library.md §1, Phase 10): every
// function throws when called. Zero-argument Task values throw only when the Task runs.

function _FileSystem_unsupported(name) {
    throw new Error('eco/system: FileSystem.' + name + ' is not supported on the JS target yet');
}

var _FileSystem_stat = F2(function(a0, a1) { _FileSystem_unsupported('stat'); });
var _FileSystem_access = F2(function(a0, a1) { _FileSystem_unsupported('access'); });
var _FileSystem_chmod = F2(function(a0, a1) { _FileSystem_unsupported('chmod'); });
var _FileSystem_chown = F4(function(a0, a1, a2, a3) { _FileSystem_unsupported('chown'); });
var _FileSystem_utimes = F4(function(a0, a1, a2, a3) { _FileSystem_unsupported('utimes'); });
var _FileSystem_rename = F2(function(a0, a1) { _FileSystem_unsupported('rename'); });
var _FileSystem_realpath = function(a0) { _FileSystem_unsupported('realpath'); };
var _FileSystem_copyFile = F2(function(a0, a1) { _FileSystem_unsupported('copyFile'); });
var _FileSystem_appendFile = F2(function(a0, a1) { _FileSystem_unsupported('appendFile'); });
var _FileSystem_readFile = function(a0) { _FileSystem_unsupported('readFile'); };
var _FileSystem_writeFile = F2(function(a0, a1) { _FileSystem_unsupported('writeFile'); });
var _FileSystem_truncate = F2(function(a0, a1) { _FileSystem_unsupported('truncate'); });
var _FileSystem_remove = F2(function(a0, a1) { _FileSystem_unsupported('remove'); });
var _FileSystem_listDirectory = function(a0) { _FileSystem_unsupported('listDirectory'); };
var _FileSystem_makeDirectory = F2(function(a0, a1) { _FileSystem_unsupported('makeDirectory'); });
var _FileSystem_makeTempDirectory = function(a0) { _FileSystem_unsupported('makeTempDirectory'); };
var _FileSystem_link = F2(function(a0, a1) { _FileSystem_unsupported('link'); });
var _FileSystem_symlink = F2(function(a0, a1) { _FileSystem_unsupported('symlink'); });
var _FileSystem_readLink = function(a0) { _FileSystem_unsupported('readLink'); };
var _FileSystem_unlink = function(a0) { _FileSystem_unsupported('unlink'); };
var _FileSystem_homeDirectory = __Scheduler_binding(function() { _FileSystem_unsupported('homeDirectory'); });
var _FileSystem_currentWorkingDirectory = __Scheduler_binding(function() { _FileSystem_unsupported('currentWorkingDirectory'); });
var _FileSystem_tmpDirectory = __Scheduler_binding(function() { _FileSystem_unsupported('tmpDirectory'); });
var _FileSystem_devNull = __Scheduler_binding(function() { _FileSystem_unsupported('devNull'); });
var _FileSystem_open = F2(function(a0, a1) { _FileSystem_unsupported('open'); });
var _FileSystem_close = function(a0) { _FileSystem_unsupported('close'); };
var _FileSystem_fstat = function(a0) { _FileSystem_unsupported('fstat'); };
var _FileSystem_fchmod = F2(function(a0, a1) { _FileSystem_unsupported('fchmod'); });
var _FileSystem_fchown = F3(function(a0, a1, a2) { _FileSystem_unsupported('fchown'); });
var _FileSystem_futimes = F3(function(a0, a1, a2) { _FileSystem_unsupported('futimes'); });
var _FileSystem_readFromOffset = F3(function(a0, a1, a2) { _FileSystem_unsupported('readFromOffset'); });
var _FileSystem_writeFromOffset = F3(function(a0, a1, a2) { _FileSystem_unsupported('writeFromOffset'); });
var _FileSystem_ftruncate = F2(function(a0, a1) { _FileSystem_unsupported('ftruncate'); });
var _FileSystem_fsync = function(a0) { _FileSystem_unsupported('fsync'); };
var _FileSystem_fdatasync = function(a0) { _FileSystem_unsupported('fdatasync'); };
var _FileSystem_readFileStream = F3(function(a0, a1, a2) { _FileSystem_unsupported('readFileStream'); });
var _FileSystem_writeFileStream = F3(function(a0, a1, a2) { _FileSystem_unsupported('writeFileStream'); });
