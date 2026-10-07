/*
import Elm.Kernel.Scheduler exposing (binding, succeed, fail, rawSpawn)
import Elm.Kernel.Utils exposing (Tuple0, Tuple2)
import Elm.Kernel.List exposing (fromArray)
import Maybe exposing (Just, Nothing)
import Eco.Kernel.Stream exposing (createChannelSource, createChannelSink, noteActivity, toBytes)
*/

// FileSystem — JS twin of src/eco-system/FileSystem/ (eco/system), plans/eco-system-library.md
// Appendix B.3 / E.3, Phase 10 (decision D15).
//
// Every B.3 kernel takes and returns exactly the native shapes: paths are POSIX Strings,
// handles and streams are Int ids, Bytes are DataViews, metadata is the 11-Int list, a
// directory listing is a List ( String, Int ), and failures are FErr = ( code, message ).
// The code is the errno name (node's err.code), or "ERR_FS_EISDIR" for a non-recursive
// remove of a directory. The message has the native kernel's shape
// "<CODE>: <description>, <syscall> '<path>'" with the same syscall and path as the native
// operation reports (FileSystemOps.cpp); the description is libuv's (node's) text for the
// errno, which differs from glibc's strerror for a few errnos (EEXIST, EISDIR, ...).
//
// File handles: the fds returned by `open` and not yet closed are kept in a set, so an
// operation on a closed handle fails with EBADF instead of reaching a reused fd number (as
// the native open-handle table does).
//
// File streams are fd-based ByteChannels (see the API at the top of Stream.js): the fd is
// opened by the readFileStream / writeFileStream task itself, so open errors are reported
// by the task (E.3 deviation from gren), and the channel serialises its requests on the fd.
//
// The one JS-only kernel, `attachWatchListener`, is used by the Elm System.File manager
// body (the native backend drops that body and runs the C++ manager, C.2).

var _FileSystem_fs = require('fs');
var _FileSystem_errorMap = null;

var _FileSystem_kChunk = 64 * 1024;


// --- Results and errors ------------------------------------------------------------------

// The libuv description of an errno ("no such file or directory").
function _FileSystem_describe(errno)
{
	if (!_FileSystem_errorMap)
	{
		_FileSystem_errorMap = require('util').getSystemErrorMap();
	}
	var entry = _FileSystem_errorMap.get(errno);
	return entry ? entry[1] : 'unknown error';
}

// The native message shape: "ENOENT: no such file or directory, open '/x'".
function _FileSystem_message(code, errno, syscall, path)
{
	var out = code + ': ' + _FileSystem_describe(errno);
	if (syscall)
	{
		out += ', ' + syscall;
		if (path)
		{
			out += " '" + path + "'";
		}
	}
	return out;
}

// FErr for a node error, reported with the native syscall and path.
function _FileSystem_errTask(err, syscall, path)
{
	if (err && typeof err.errno === 'number' && err.errno < 0 && typeof err.code === 'string')
	{
		return __Scheduler_fail(__Utils_Tuple2(err.code, _FileSystem_message(err.code, err.errno, syscall, path)));
	}
	var code = (err && typeof err.code === 'string') ? err.code : 'EIO';
	var message = (err && err.message) ? err.message : String(err);
	return __Scheduler_fail(__Utils_Tuple2(code, message));
}

// FErr for an errno name raised by this kernel (EISDIR, EINVAL).
function _FileSystem_errnoTask(code, syscall, path)
{
	var errno = require('os').constants.errno[code];
	return __Scheduler_fail(__Utils_Tuple2(code, _FileSystem_message(code, -errno, syscall, path)));
}

// A P-mode task: `run(ok, fail)` starts the node operation; ok(value) succeeds, and
// fail(err, syscall, path) fails with the FErr built from a node error.
function _FileSystem_task(run)
{
	return __Scheduler_binding(function(callback)
	{
		__Stream_noteActivity();
		run(
			function(value) { callback(__Scheduler_succeed(value)); },
			function(err, syscall, path) { callback(_FileSystem_errTask(err, syscall, path)); }
		);
	});
}

// A task for a node call `fn(args..., cb(err))` that succeeds with ().
function _FileSystem_unitTask(fn, args, syscall, path)
{
	return _FileSystem_task(function(ok, fail)
	{
		fn.apply(_FileSystem_fs, args.concat([function(err)
		{
			if (err) fail(err, syscall, path);
			else ok(__Utils_Tuple0);
		}]));
	});
}

function _FileSystem_bytesToBuffer(bytes)
{
	return Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength);
}

function _FileSystem_bufferToBytes(buf)
{
	return __Stream_toBytes(new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength));
}


// --- Metadata ------------------------------------------------------------------------------

// Entity codes of B.3 (0 File, 1 Directory, 2 Socket, 3 Symlink, 4 Device, 5 Pipe), tested
// in the native order. Works for Stats and Dirents.
function _FileSystem_entity(s)
{
	if (s.isFile()) return 0;
	if (s.isDirectory()) return 1;
	if (s.isFIFO()) return 5;
	if (s.isSocket()) return 2;
	if (s.isSymbolicLink()) return 3;
	return 4;
}

function _FileSystem_ms(ns)
{
	return Number(ns / BigInt(1000000));
}

// BigIntStats -> [entityType, dev, uid, gid, size, blksize, blocks, atimeMs, mtimeMs,
// ctimeMs, birthtimeMs]; whole milliseconds, birth time falling back to ctime (§3.8).
function _FileSystem_statList(s)
{
	var ctime = _FileSystem_ms(s.ctimeNs);
	var birth = s.birthtimeNs > BigInt(0) ? _FileSystem_ms(s.birthtimeNs) : ctime;
	return __List_fromArray([
		_FileSystem_entity(s),
		Number(s.dev),
		Number(s.uid),
		Number(s.gid),
		Number(s.size),
		Number(s.blksize),
		Number(s.blocks),
		_FileSystem_ms(s.atimeNs),
		_FileSystem_ms(s.mtimeNs),
		ctime,
		birth
	]);
}


// --- Path operations -----------------------------------------------------------------------

// stat : Bool -> String -> Task FErr (List Int)
var _FileSystem_stat = F2(function(resolveLink, path)
{
	return _FileSystem_task(function(ok, fail)
	{
		var syscall = resolveLink ? 'stat' : 'lstat';
		_FileSystem_fs[syscall](path, { bigint: true }, function(err, s)
		{
			if (err) fail(err, syscall, path);
			else ok(_FileSystem_statList(s));
		});
	});
});

// access : Int -> String -> Task FErr ()   (R=4, W=2, X=1; 0 = F_OK)
var _FileSystem_access = F2(function(mode, path)
{
	return _FileSystem_unitTask(_FileSystem_fs.access, [path, mode & 7], 'access', path);
});

var _FileSystem_chmod = F2(function(mode, path)
{
	return _FileSystem_unitTask(_FileSystem_fs.chmod, [path, mode], 'chmod', path);
});

// chown : Bool -> Int -> Int -> String -> Task FErr ()
var _FileSystem_chown = F4(function(resolveLink, uid, gid, path)
{
	return resolveLink
		? _FileSystem_unitTask(_FileSystem_fs.chown, [path, uid, gid], 'chown', path)
		: _FileSystem_unitTask(_FileSystem_fs.lchown, [path, uid, gid], 'lchown', path);
});

// utimes : Bool -> Int -> Int -> String -> Task FErr ()   (whole seconds)
var _FileSystem_utimes = F4(function(resolveLink, atime, mtime, path)
{
	return resolveLink
		? _FileSystem_unitTask(_FileSystem_fs.utimes, [path, atime, mtime], 'utime', path)
		: _FileSystem_unitTask(_FileSystem_fs.lutimes, [path, atime, mtime], 'lutime', path);
});

// rename : String -> String -> Task FErr ()   (from, to); errors report `to`
var _FileSystem_rename = F2(function(from, to)
{
	return _FileSystem_unitTask(_FileSystem_fs.rename, [from, to], 'rename', to);
});

var _FileSystem_realpath = function(path)
{
	return _FileSystem_task(function(ok, fail)
	{
		_FileSystem_fs.realpath.native(path, function(err, resolved)
		{
			if (err) fail(err, 'realpath', path);
			else ok(resolved);
		});
	});
};

// copyFile : String -> String -> Task FErr ()   (src, dest): overwrites, copies the mode
// of src; errors report dest; a directory src fails with EISDIR before dest is touched.
var _FileSystem_copyFile = F2(function(src, dest)
{
	return __Scheduler_binding(function(callback)
	{
		__Stream_noteActivity();
		_FileSystem_fs.stat(src, function(err, s)
		{
			if (err)
			{
				callback(_FileSystem_errTask(err, 'copyfile', dest));
				return;
			}
			if (s.isDirectory())
			{
				callback(_FileSystem_errnoTask('EISDIR', 'copyfile', dest));
				return;
			}
			_FileSystem_fs.copyFile(src, dest, function(err2)
			{
				callback(err2 ? _FileSystem_errTask(err2, 'copyfile', dest) : __Scheduler_succeed(__Utils_Tuple0));
			});
		});
	});
});

// open (flag) + write everything + close; open failures report "open", the rest "write".
function _FileSystem_writeWhole(flag, bytes, path)
{
	return _FileSystem_task(function(ok, fail)
	{
		_FileSystem_fs.writeFile(path, _FileSystem_bytesToBuffer(bytes), { flag: flag, mode: 438 }, function(err)
		{
			if (err) fail(err, err.syscall === 'open' ? 'open' : 'write', path);
			else ok(__Utils_Tuple0);
		});
	});
}

var _FileSystem_appendFile = F2(function(bytes, path)
{
	return _FileSystem_writeWhole('a', bytes, path);
});

var _FileSystem_writeFile = F2(function(bytes, path)
{
	return _FileSystem_writeWhole('w', bytes, path);
});

var _FileSystem_readFile = function(path)
{
	return _FileSystem_task(function(ok, fail)
	{
		_FileSystem_fs.readFile(path, function(err, buf)
		{
			if (err) fail(err, err.syscall === 'open' ? 'open' : 'read', path);
			else ok(_FileSystem_bufferToBytes(buf));
		});
	});
};

// truncate : Int -> String -> Task FErr ()
var _FileSystem_truncate = F2(function(length, path)
{
	return _FileSystem_unitTask(_FileSystem_fs.truncate, [path, length], 'truncate', path);
});

// remove : Bool -> String -> Task FErr ()   (recursive, path). A directory without
// `recursive` fails with ERR_FS_EISDIR (node's fs.rm); a symlink is removed, not followed.
var _FileSystem_remove = F2(function(recursive, path)
{
	return _FileSystem_task(function(ok, fail)
	{
		_FileSystem_fs.lstat(path, function(err, s)
		{
			if (err)
			{
				fail(err, 'rm', path);
			}
			else if (s.isDirectory())
			{
				if (!recursive)
				{
					var e = new Error('Path is a directory: rm returned EISDIR (is a directory) ' + path);
					e.code = 'ERR_FS_EISDIR';
					fail(e, 'rm', path);
					return;
				}
				_FileSystem_fs.rm(path, { recursive: true, force: false }, function(err2)
				{
					if (err2) fail(err2, 'rm', path);
					else ok(__Utils_Tuple0);
				});
			}
			else
			{
				_FileSystem_fs.unlink(path, function(err2)
				{
					if (err2) fail(err2, 'rm', path);
					else ok(__Utils_Tuple0);
				});
			}
		});
	});
});

// listDirectory : String -> Task FErr (List ( String, Int )), sorted by strcmp (bytewise
// UTF-8). node's readdir falls back to lstat for DT_UNKNOWN entries.
var _FileSystem_listDirectory = function(path)
{
	return _FileSystem_task(function(ok, fail)
	{
		_FileSystem_fs.readdir(path, { withFileTypes: true }, function(err, entries)
		{
			if (err)
			{
				fail(err, 'scandir', path);
				return;
			}
			var keyed = entries.map(function(d)
			{
				return { name: d.name, key: Buffer.from(d.name, 'utf8'), kind: _FileSystem_entity(d) };
			});
			keyed.sort(function(x, y) { return Buffer.compare(x.key, y.key); });
			ok(__List_fromArray(keyed.map(function(e) { return __Utils_Tuple2(e.name, e.kind); })));
		});
	});
};

// makeDirectory : Bool -> String -> Task FErr ()
var _FileSystem_makeDirectory = F2(function(recursive, path)
{
	return _FileSystem_task(function(ok, fail)
	{
		_FileSystem_fs.mkdir(path, { recursive: !!recursive, mode: 511 }, function(err)
		{
			if (err) fail(err, 'mkdir', path);
			else ok(__Utils_Tuple0);
		});
	});
});

// makeTempDirectory : String -> Task FErr String   (prefix; mkdtemp(tmp/prefix XXXXXX), E.3)
var _FileSystem_makeTempDirectory = function(prefix)
{
	return _FileSystem_task(function(ok, fail)
	{
		var tmp = _FileSystem_tmpDirectoryString();
		var base = tmp.length && tmp[tmp.length - 1] === '/' ? tmp + prefix : tmp + '/' + prefix;
		_FileSystem_fs.mkdtemp(base, function(err, dir)
		{
			if (err) fail(err, 'mkdtemp', base);
			else ok(dir);
		});
	});
};

// link / symlink : String -> String -> Task FErr ()   (src, dest); errors report dest
var _FileSystem_link = F2(function(src, dest)
{
	return _FileSystem_unitTask(_FileSystem_fs.link, [src, dest], 'link', dest);
});

var _FileSystem_symlink = F2(function(src, dest)
{
	return _FileSystem_unitTask(_FileSystem_fs.symlink, [src, dest], 'symlink', dest);
});

var _FileSystem_readLink = function(path)
{
	return _FileSystem_task(function(ok, fail)
	{
		_FileSystem_fs.readlink(path, function(err, target)
		{
			if (err) fail(err, 'readlink', path);
			else ok(target);
		});
	});
};

var _FileSystem_unlink = function(path)
{
	return _FileSystem_unitTask(_FileSystem_fs.unlink, [path], 'unlink', path);
};


// --- Directory getters (S mode, E.3) ---------------------------------------------------------

function _FileSystem_tmpDirectoryString()
{
	var vars = ['TMPDIR', 'TMP', 'TEMP'];
	for (var i = 0; i < vars.length; i++)
	{
		var v = process.env[vars[i]];
		if (v)
		{
			while (v.length > 1 && v[v.length - 1] === '/')
			{
				v = v.slice(0, -1);
			}
			return v;
		}
	}
	return process.platform === 'win32' ? 'C:/Windows/Temp' : '/tmp';
}

var _FileSystem_homeDirectory = __Scheduler_binding(function(callback)
{
	var home = process.env.HOME;
	if (!home)
	{
		try
		{
			home = require('os').userInfo().homedir || '';
		}
		catch (e)
		{
			home = '';
		}
	}
	callback(__Scheduler_succeed(home));
});

var _FileSystem_currentWorkingDirectory = __Scheduler_binding(function(callback)
{
	var cwd;
	try
	{
		cwd = process.cwd();
	}
	catch (e)
	{
		cwd = '.';
	}
	callback(__Scheduler_succeed(cwd));
});

var _FileSystem_tmpDirectory = __Scheduler_binding(function(callback)
{
	callback(__Scheduler_succeed(_FileSystem_tmpDirectoryString()));
});

var _FileSystem_devNull = __Scheduler_binding(function(callback)
{
	callback(__Scheduler_succeed(process.platform === 'win32' ? '//./nul' : '/dev/null'));
});


// --- File handles ----------------------------------------------------------------------------

// fds returned by `open` and not yet closed.
var _FileSystem_openHandles = new Set();

var _FileSystem_openFlags = { 'r': 1, 'w': 1, 'r+': 1, 'wx': 1, 'w+': 1, 'wx+': 1 };

function _FileSystem_badHandle()
{
	return __Scheduler_fail(__Utils_Tuple2('EBADF', 'EBADF: bad file descriptor'));
}

// A task on an open handle: fails with EBADF when `fd` is not open, else runs `run`.
function _FileSystem_handleTask(fd, run)
{
	return __Scheduler_binding(function(callback)
	{
		if (!_FileSystem_openHandles.has(fd))
		{
			callback(_FileSystem_badHandle());
			return;
		}
		__Stream_noteActivity();
		run(
			function(value) { callback(__Scheduler_succeed(value)); },
			function(err, syscall) { callback(_FileSystem_errTask(err, syscall, '')); }
		);
	});
}

function _FileSystem_handleUnitTask(fd, fn, args, syscall)
{
	return _FileSystem_handleTask(fd, function(ok, fail)
	{
		fn.apply(_FileSystem_fs, [fd].concat(args, [function(err)
		{
			if (err) fail(err, syscall);
			else ok(__Utils_Tuple0);
		}]));
	});
}

// open : String -> String -> Task FErr Int   (nodeFlags, path), mode 0666 (node opens with
// O_CLOEXEC)
var _FileSystem_open = F2(function(flags, path)
{
	return __Scheduler_binding(function(callback)
	{
		if (!_FileSystem_openFlags.hasOwnProperty(flags))
		{
			callback(_FileSystem_errnoTask('EINVAL', 'open', path));
			return;
		}
		__Stream_noteActivity();
		_FileSystem_fs.open(path, flags, 438, function(err, fd)
		{
			if (err)
			{
				callback(_FileSystem_errTask(err, 'open', path));
				return;
			}
			_FileSystem_openHandles.add(fd);
			callback(__Scheduler_succeed(fd));
		});
	});
});

// close : Int -> Task FErr ()   (the fd leaves the open set before it is closed)
var _FileSystem_close = function(fd)
{
	return __Scheduler_binding(function(callback)
	{
		if (!_FileSystem_openHandles.has(fd))
		{
			callback(_FileSystem_badHandle());
			return;
		}
		_FileSystem_openHandles.delete(fd);
		__Stream_noteActivity();
		_FileSystem_fs.close(fd, function(err)
		{
			callback(err && err.code !== 'EINTR' ? _FileSystem_errTask(err, 'close', '') : __Scheduler_succeed(__Utils_Tuple0));
		});
	});
};

var _FileSystem_fstat = function(fd)
{
	return _FileSystem_handleTask(fd, function(ok, fail)
	{
		_FileSystem_fs.fstat(fd, { bigint: true }, function(err, s)
		{
			if (err) fail(err, 'fstat');
			else ok(_FileSystem_statList(s));
		});
	});
};

var _FileSystem_fchmod = F2(function(fd, mode)
{
	return _FileSystem_handleUnitTask(fd, _FileSystem_fs.fchmod, [mode], 'fchmod');
});

var _FileSystem_fchown = F3(function(fd, uid, gid)
{
	return _FileSystem_handleUnitTask(fd, _FileSystem_fs.fchown, [uid, gid], 'fchown');
});

var _FileSystem_futimes = F3(function(fd, atime, mtime)
{
	return _FileSystem_handleUnitTask(fd, _FileSystem_fs.futimes, [atime, mtime], 'futime');
});

// readFromOffset : Int -> Int -> Int -> Task FErr Bytes   (fd, offset, length): offset < 0
// reads from 0, length < 0 reads to EOF; stops early at EOF.
var _FileSystem_readFromOffset = F3(function(fd, offset, length)
{
	return _FileSystem_handleTask(fd, function(ok, fail)
	{
		var pos = offset < 0 ? 0 : offset;
		var chunks = [];
		var total = 0;
		var step = function()
		{
			var want = length < 0 ? _FileSystem_kChunk : Math.min(_FileSystem_kChunk, length - total);
			if (want <= 0)
			{
				ok(_FileSystem_bufferToBytes(Buffer.concat(chunks, total)));
				return;
			}
			var buf = Buffer.allocUnsafe(want);
			_FileSystem_fs.read(fd, buf, 0, want, pos + total, function(err, n)
			{
				if (err)
				{
					if (err.code === 'EINTR') { step(); return; }
					fail(err, 'read');
					return;
				}
				if (n === 0)
				{
					ok(_FileSystem_bufferToBytes(Buffer.concat(chunks, total)));
					return;
				}
				chunks.push(buf.subarray(0, n));
				total += n;
				step();
			});
		};
		step();
	});
});

// Writes all of `buf` to fd at `pos` (null: the current position). done(err).
function _FileSystem_writeAll(fd, buf, pos, done)
{
	var off = 0;
	var step = function()
	{
		if (off >= buf.length)
		{
			done(null);
			return;
		}
		_FileSystem_fs.write(fd, buf, off, buf.length - off, pos === null ? null : pos + off, function(err, n)
		{
			if (err)
			{
				if (err.code === 'EINTR') { step(); return; }
				done(err);
				return;
			}
			off += n;
			step();
		});
	};
	step();
}

// writeFromOffset : Int -> Int -> Bytes -> Task FErr ()   (fd, offset, bytes); a negative
// offset writes at the current file position (node's -1).
var _FileSystem_writeFromOffset = F3(function(fd, offset, bytes)
{
	return _FileSystem_handleTask(fd, function(ok, fail)
	{
		_FileSystem_writeAll(fd, _FileSystem_bytesToBuffer(bytes), offset < 0 ? null : offset, function(err)
		{
			if (err) fail(err, 'write');
			else ok(__Utils_Tuple0);
		});
	});
});

var _FileSystem_ftruncate = F2(function(fd, length)
{
	return _FileSystem_handleUnitTask(fd, _FileSystem_fs.ftruncate, [length], 'ftruncate');
});

var _FileSystem_fsync = function(fd)
{
	return _FileSystem_handleUnitTask(fd, _FileSystem_fs.fsync, [], 'fsync');
};

var _FileSystem_fdatasync = function(fd)
{
	return _FileSystem_handleUnitTask(fd, _FileSystem_fs.fdatasync, [], 'fdatasync');
};


// --- File streams -------------------------------------------------------------------------
//
// An fd-based ByteChannel (Stream.js API), the twin of the native FdChannel with
// FdChannelOptions:
//   position         where the next read/write goes; null = the fd's current position
//                    (O_APPEND writes, `w` streams)
//   readLimit        bytes left to read (-1: no limit); `Between` uses an inclusive end
//   truncateOnClose  on a graceful close, truncate the file at the position reached
//                    (ReplaceFrom: the file ends at start + bytes written)
// The channel owns the fd. Requests run one at a time, in order. shutdown() fails every
// queued request with ECANCELED at once, the one in flight when it finishes, and closes the
// fd after that.

function _FileSystem_cancelled()
{
	var e = new Error('operation canceled');
	e.code = 'ECANCELED';
	e.errno = -require('os').constants.errno.ECANCELED;
	return e;
}

function _FileSystem_fdChannel(fd, position, readLimit, truncateOnClose)
{
	var queue = [];        // { run: function(finish), cancel: function() }
	var busy = false;
	var ending = false;    // close or shutdown requested: no new requests
	var dead = false;      // shutdown: results are replaced by ECANCELED
	var released = false;

	function release(done)
	{
		if (released)
		{
			if (done) done(null);
			return;
		}
		released = true;
		_FileSystem_fs.close(fd, function(err)
		{
			if (done) done(err && err.code !== 'EINTR' ? err : null);
		});
	}

	function next()
	{
		if (busy) return;
		if (!queue.length)
		{
			if (dead) release(null);
			return;
		}
		busy = true;
		var op = queue.shift();
		op.run(function()
		{
			busy = false;
			next();
		});
	}

	function enqueue(run, cancel)
	{
		queue.push({ run: run, cancel: cancel });
		next();
	}

	return {
		requestRead: function(maxBytes, done)
		{
			if (ending)
			{
				done(_FileSystem_cancelled(), null);
				return;
			}
			enqueue(function(finish)
			{
				var want = maxBytes > 0 ? maxBytes : _FileSystem_kChunk;
				if (readLimit >= 0) want = Math.min(want, readLimit);
				if (want <= 0)
				{
					finish();
					done(dead ? _FileSystem_cancelled() : null, null);
					return;
				}
				var buf = Buffer.allocUnsafe(want);
				var attempt = function()
				{
					_FileSystem_fs.read(fd, buf, 0, want, position, function(err, n)
					{
						if (err && err.code === 'EINTR' && !dead) { attempt(); return; }
						finish();
						if (dead) { done(_FileSystem_cancelled(), null); return; }
						if (err) { done(err, null); return; }
						if (n === 0) { done(null, null); return; }
						if (position !== null) position += n;
						if (readLimit >= 0) readLimit -= n;
						done(null, new Uint8Array(buf.buffer, buf.byteOffset, n));
					});
				};
				attempt();
			}, function() { done(_FileSystem_cancelled(), null); });
		},
		requestWrite: function(bytes, done)
		{
			if (ending)
			{
				done(_FileSystem_cancelled());
				return;
			}
			enqueue(function(finish)
			{
				var buf = Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength);
				_FileSystem_writeAll(fd, buf, position, function(err)
				{
					if (!err && position !== null) position += buf.length;
					finish();
					done(dead ? _FileSystem_cancelled() : err);
				});
			}, function() { done(_FileSystem_cancelled()); });
		},
		close: function(done)
		{
			if (ending)
			{
				if (done) done(dead ? _FileSystem_cancelled() : null);
				return;
			}
			ending = true;
			enqueue(function(finish)
			{
				var closeFd = function(firstErr)
				{
					release(function(err)
					{
						finish();
						if (done) done(firstErr || err);
					});
				};
				if (truncateOnClose && position !== null)
				{
					_FileSystem_fs.ftruncate(fd, position, function(err) { closeFd(err); });
				}
				else
				{
					closeFd(null);
				}
			}, function() { if (done) done(_FileSystem_cancelled()); });
		},
		shutdown: function()
		{
			if (dead) return;
			dead = true;
			ending = true;
			var pending = queue;
			queue = [];
			for (var i = 0; i < pending.length; i++)
			{
				pending[i].cancel();
			}
			if (!busy) release(null);
		}
	};
}

// readFileStream : Int -> Int -> String -> Task FErr Int   (start, endInclusive or -1,
// path) -> a ChannelSource id owning the fd. A directory fails with EISDIR here.
var _FileSystem_readFileStream = F3(function(start, end, path)
{
	return _FileSystem_task(function(ok, fail)
	{
		_FileSystem_fs.open(path, 'r', function(err, fd)
		{
			if (err)
			{
				fail(err, 'open', path);
				return;
			}
			_FileSystem_fs.fstat(fd, function(err2, s)
			{
				if (err2 || s.isDirectory())
				{
					_FileSystem_fs.close(fd, function() {});
					if (err2)
					{
						fail(err2, 'fstat', path);
					}
					else
					{
						var e = new Error('EISDIR');
						e.code = 'EISDIR';
						e.errno = -require('os').constants.errno.EISDIR;
						fail(e, 'read', path);
					}
					return;
				}
				var from = start < 0 ? 0 : start;
				var limit = end >= 0 ? (end >= from ? end - from + 1 : 0) : -1;
				ok(__Stream_createChannelSource(_FileSystem_fdChannel(fd, from, limit, false)));
			});
		});
	});
});

// writeFileStream : Int -> Int -> String -> Task FErr Int   (mode, position, path) -> a
// ChannelSink id owning the fd. Modes: 0 Replace (`w`), 1 ReplaceFrom (`r+` at position,
// truncated on close where the writing stopped), 2 Append (`a`).
var _FileSystem_writeFileStream = F3(function(mode, position, path)
{
	return _FileSystem_task(function(ok, fail)
	{
		var flags = mode === 1 ? 'r+' : (mode === 2 ? 'a' : 'w');
		_FileSystem_fs.open(path, flags, 438, function(err, fd)
		{
			if (err)
			{
				fail(err, 'open', path);
				return;
			}
			var pos = mode === 1 ? (position > 0 ? position : 0) : null;
			ok(__Stream_createChannelSink(_FileSystem_fdChannel(fd, pos, -1, mode === 1)));
		});
	});
});


// --- JS-only: the listener for the Elm System.File manager (C.2) ---------------------------
//
// attachWatchListener : String -> Bool -> (( Int, Maybe String ) -> Task Never ()) -> Task Never ()
// A binding that never completes: it watches `path` (recursively when asked) with fs.watch
// and, for every event, spawns `toTask ( kind, relativePath )` with kind 0 Changed ("change")
// or 1 Moved ("rename"). Killing its process closes the watcher. A path that cannot be
// watched produces no events (as natively; gren ignores watch errors too). An active watcher
// keeps the process alive, as the native watch holds a pendingAsync count.
var _FileSystem_attachWatchListener = F3(function(path, recursive, toTask)
{
	return __Scheduler_binding(function(callback)
	{
		var watcher = null;
		try
		{
			watcher = _FileSystem_fs.watch(path, { recursive: !!recursive, persistent: true }, function(eventType, filename)
			{
				var kind = eventType === 'rename' ? 1 : (eventType === 'change' ? 0 : -1);
				if (kind < 0) return;
				var rel = filename === null || filename === undefined ? null : String(filename);
				__Scheduler_rawSpawn(toTask(__Utils_Tuple2(kind, rel ? __Maybe_Just(rel) : __Maybe_Nothing)));
			});
			watcher.on('error', function() {});
		}
		catch (e)
		{
			watcher = null;
		}
		return function()
		{
			if (watcher)
			{
				watcher.close();
				watcher = null;
			}
		};
	});
});
