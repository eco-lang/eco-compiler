/*
import Elm.Kernel.Scheduler exposing (binding, succeed, fail, rawSpawn)
import Elm.Kernel.Utils exposing (Tuple0, Tuple2, Tuple3)
import Elm.Kernel.List exposing (toArray)
import Maybe exposing (Just, Nothing)
import Eco.Kernel.Stream exposing (createChannelSource, createChannelSink, nodeReadableChannel, nodeWritableChannel, noteActivity, toBytes)
*/

// ChildProcess — JS twin of src/eco-system/ChildProcess/ (eco/system),
// plans/eco-system-library.md Appendix B.4, C.3, E.4, Phase 5 step 5.2, Phase 10 (D15).
//
// `run` takes and returns exactly the B.4 shapes. It is built on node:child_process
// `spawn` (not `execFile`) so that it follows the native semantics:
//   * stdin is /dev/null; stdout and stderr are collected, at most maxBytes each
//     (0 = no limit). A stream that exceeds the limit is truncated at it, the child gets
//     SIGTERM and the run fails with ProgramError -1 (E.4).
//   * runDurationMs (0 = no limit) arms a timer; on expiry the child gets SIGTERM and the
//     run fails with ProgramError -1. The timer is cleared when the run completes.
//   * The run completes once the child has exited AND both pipes reached end of input
//     (node's 'close'); after a kill it stops waiting for the pipes at the exit, so a
//     grandchild keeping them open cannot delay a killed run.
//   * exit 0 → ( stdout, stderr ); a non-zero exit → ProgramError code; a signal death or
//     a kill → ProgramError -1; a spawn failure → InitError with the errno name.
//   * Process.kill on the run task SIGTERMs the child; the task then never completes.
//
// `spawn` is JS-only: it is used by the Elm effect-manager body in System/Process.elm
// (the native backend runs the C++ manager, C.3, and never references it).

var _ChildProcess_cp = null;

function _ChildProcess_module()
{
	return _ChildProcess_cp || (_ChildProcess_cp = require('child_process'));
}


// --- Spec decoding (shared by run and spawn) ------------------------------------------

// The file to execute and its arguments (Phase 5 step 5.2 "Shell"): NoShell runs the
// program directly (PATH search); DefaultShell is `/bin/sh -c "<program> <args>"`, the
// program and arguments joined by spaces as gren does; CustomShell s is `s -c …`.
function _ChildProcess_command(program, args, shell)
{
	var argv = __List_toArray(args);
	if (shell.a === 0)
	{
		return { __file: program, __args: argv };
	}
	var line = [program].concat(argv).join(' ');
	var file = shell.a === 2 && shell.b !== '' ? shell.b : '/bin/sh';
	return { __file: file, __args: ['-c', line] };
}

// Inherit (0) = the parent's environment; Merge (1) = it overlaid with the pairs;
// Replace (2) = the pairs only.
function _ChildProcess_environment(env)
{
	var mode = env.a;
	if (mode === 0)
	{
		return process.env;
	}
	var out = {};
	if (mode === 1)
	{
		for (var key in process.env)
		{
			out[key] = process.env[key];
		}
	}
	var pairs = __List_toArray(env.b);
	for (var i = 0; i < pairs.length; i++)
	{
		out[pairs[i].a] = pairs[i].b;
	}
	return out;
}

// cwd: ( inheritCwd, cwd )
function _ChildProcess_options(cwd, env, stdio)
{
	var opts = { env: _ChildProcess_environment(env), stdio: stdio };
	if (!cwd.a)
	{
		opts.cwd = cwd.b;
	}
	return opts;
}

// Native uses posix_spawnp, which searches the PARENT's PATH (unset: /bin:/usr/bin);
// libuv would search the child's (so MergeWithEnvironmentVariables PATH=… would change
// which program runs). Resolve a bare name here the same way and pass the full path;
// argv[0] stays the name as given. Relative PATH entries are taken relative to the
// child's working directory (glibc searches after the chdir). A name not found is passed
// on unchanged, for libuv to report.
function _ChildProcess_resolve(command, opts)
{
	opts.argv0 = command.__file;
	var file = command.__file;
	if (process.platform === 'win32' || file === '' || file.indexOf('/') >= 0)
	{
		return file;
	}
	var fs = require('fs');
	var path = require('path');
	var dirs = (process.env.PATH === undefined ? '/bin:/usr/bin' : process.env.PATH).split(':');
	var base = opts.cwd !== undefined ? path.resolve(opts.cwd) : process.cwd();
	for (var i = 0; i < dirs.length; i++)
	{
		var candidate = path.resolve(base, dirs[i] === '' ? '.' : dirs[i], file);
		try
		{
			if (fs.statSync(candidate).isFile())
			{
				fs.accessSync(candidate, fs.constants.X_OK);
				return candidate;
			}
		}
		catch (e)
		{
		}
	}
	return file;
}

function _ChildProcess_start(command, opts)
{
	return _ChildProcess_module().spawn(_ChildProcess_resolve(command, opts), command.__args, opts);
}

// The errno name of a spawn failure ("ENOENT"); node's own code for argument errors.
function _ChildProcess_errorName(e)
{
	return e && typeof e.code === 'string' ? e.code : 'EINVAL';
}

function _ChildProcess_signalNumber(name)
{
	var n = name ? require('os').constants.signals[name] : 0;
	return typeof n === 'number' ? n : 0;
}

function _ChildProcess_concat(chunks, length)
{
	var out = new Uint8Array(length);
	var at = 0;
	for (var i = 0; i < chunks.length; i++)
	{
		out.set(chunks[i], at);
		at += chunks[i].length;
	}
	return __Stream_toBytes(out);
}


// --- B.4 run ---------------------------------------------------------------------------

// run : String -> List String -> ( Int, String ) -> ( Bool, String )
//       -> ( Int, List ( String, String ) ) -> ( Int, Int )
//       -> Task ( Int, String, ( Int, Bytes, Bytes ) ) ( Bytes, Bytes )
var _ChildProcess_run = F6(function(program, args, shell, cwd, env, limits)
{
	return __Scheduler_binding(function(callback)
	{
		var maxBytes = limits.a > 0 ? limits.a : 0;
		var runMs = limits.b > 0 ? limits.b : 0;
		var command = _ChildProcess_command(program, args, shell);

		function initError(e)
		{
			callback(__Scheduler_fail(__Utils_Tuple3(0, _ChildProcess_errorName(e),
				__Utils_Tuple3(0, __Stream_toBytes(new Uint8Array(0)), __Stream_toBytes(new Uint8Array(0))))));
		}

		var child;
		try
		{
			child = _ChildProcess_start(command, _ChildProcess_options(cwd, env, ['ignore', 'pipe', 'pipe']));
		}
		catch (e)
		{
			initError(e);
			return;
		}
		__Stream_noteActivity();

		var out = { __chunks: [], __length: 0, __done: false, __stream: child.stdout };
		var err = { __chunks: [], __length: 0, __done: false, __stream: child.stderr };
		var exited = false, exitCode = null, exitSignal = null;
		var killed = false;     // SIGTERM sent (runDuration, overflow, Process.kill)
		var overflow = false;
		var aborted = false;    // the task was killed: never resume it
		var finished = false;
		var timer = null;

		function kill()
		{
			if (exited) return;   // never signal a pid we already saw exit
			killed = true;
			try { child.kill('SIGTERM'); } catch (e) {}
		}

		function stopReading()
		{
			[out, err].forEach(function(s)
			{
				s.__done = true;
				if (s.__stream && !s.__stream.destroyed) s.__stream.destroy();
			});
		}

		function finish()
		{
			if (finished) return;
			finished = true;
			if (timer !== null)
			{
				clearTimeout(timer);
				timer = null;
			}
			if (aborted) return;
			var code = (!killed && !overflow && exitSignal === null && exitCode !== null) ? exitCode : -1;
			var outBytes = _ChildProcess_concat(out.__chunks, out.__length);
			var errBytes = _ChildProcess_concat(err.__chunks, err.__length);
			callback(code === 0
				? __Scheduler_succeed(__Utils_Tuple2(outBytes, errBytes))
				: __Scheduler_fail(__Utils_Tuple3(1, '', __Utils_Tuple3(code, outBytes, errBytes))));
		}

		function advance()
		{
			if (exited && !(out.__done && err.__done) && killed) stopReading();
			if (exited && out.__done && err.__done) finish();
		}

		function collect(s)
		{
			s.__stream.on('data', function(chunk)
			{
				if (s.__done) return;
				s.__chunks.push(chunk);
				s.__length += chunk.length;
				if (maxBytes > 0 && s.__length > maxBytes)
				{
					// E.4: truncated at the limit, the child is killed.
					var last = s.__chunks.length - 1;
					s.__chunks[last] = chunk.subarray(0, chunk.length - (s.__length - maxBytes));
					s.__length = maxBytes;
					overflow = true;
					stopReading();
					kill();
					advance();
				}
			});
			s.__stream.on('error', function() {});
			s.__stream.on('close', function()
			{
				s.__done = true;
				advance();
			});
		}

		child.on('error', function(e)
		{
			if (finished) return;
			if (child.pid === undefined)
			{
				// The spawn failed (node reports it asynchronously): InitError.
				finished = true;
				if (timer !== null) clearTimeout(timer);
				stopReading();
				if (!aborted) initError(e);
			}
		});

		collect(out);
		collect(err);

		child.on('exit', function(code, signal)
		{
			exited = true;
			exitCode = code;
			exitSignal = signal;
			advance();
		});

		if (runMs > 0)
		{
			timer = setTimeout(function()
			{
				timer = null;
				if (!exited)
				{
					kill();
				}
				else if (!(out.__done && err.__done))
				{
					killed = true;   // exited, a grandchild holds the pipes: stop waiting
					advance();
				}
			}, runMs);
		}

		return function()
		{
			aborted = true;
			kill();
			advance();
		};
	});
});


// A child's output pipe for the readable channel adapter, which attaches to the Node
// stream on its first read (and then sees whether it already ended or failed). Errors
// before then are kept by the socket, not thrown.
function _ChildProcess_pipe(socket)
{
	socket.on('error', function() {});
	return socket;
}


// --- JS-only: the spawn kernel of the Elm System.Process manager (C.3) ----------------
//
// spawn : (( Int, Int ) -> Task Never ()) -> spec -> Task Never ( Process.Id, Maybe ( Int, Int, Int ) )
//   spec = ( ( program, args ), ( ( shellKind, customShell ), ( inheritCwd, cwd ) ),
//            ( ( envMode, pairs ), runDurationMs, connectionKind ) )
//   connectionKind: 0 Integrated, 1 External, 2 Ignored, 3 Detached.
//
// Spawns the child and an Elm process standing for it (a binding that completes when the
// child exits; its kill handle SIGTERMs the child), and returns ( processId, streams ) for
// the manager to hand to onInit: streams is Just ( stdinId, stdoutId, stderrId ) for
// External (channel pairs over the child's pipes), otherwise Nothing. When the child
// exits, the Elm process completes and `sendExit ( exitCode, signal )` is spawned
// (exitCode = 128 + signal for a signal death). A spawn failure still returns the init
// value (a finished process; External gets stream ids 0) and then sends
// ( -errno, 0 ), as the native manager and gren's 'error' event do. Detached children
// run in their own session and do not keep the program alive.
var _ChildProcess_spawn = F2(function(sendExit, spec)
{
	return __Scheduler_binding(function(callback)
	{
		var command = _ChildProcess_command(spec.a.a, spec.a.b, spec.b.a);
		var runMs = spec.c.b > 0 ? spec.c.b : 0;
		var kind = spec.c.c;
		var stdio = kind === 0 ? 'inherit' : kind === 1 ? 'pipe' : 'ignore';

		var job = { __exited: false, __resume: null, __finished: false, __timer: null };
		var child = null;
		var failure = null;
		try
		{
			var opts = _ChildProcess_options(spec.b.b, spec.c.a, stdio);
			opts.detached = kind === 3;
			child = _ChildProcess_start(command, opts);
		}
		catch (e)
		{
			failure = e;
		}

		function exit(code, sig)
		{
			if (job.__finished) return;
			job.__finished = true;
			job.__exited = true;
			if (job.__timer !== null)
			{
				clearTimeout(job.__timer);
				job.__timer = null;
			}
			var resume = job.__resume;
			job.__resume = null;
			if (resume) resume(__Scheduler_succeed(__Utils_Tuple0));
			__Scheduler_rawSpawn(sendExit(__Utils_Tuple2(code, sig)));
		}

		function kill()
		{
			if (job.__exited || !child) return;
			try { child.kill('SIGTERM'); } catch (e) {}
		}

		var streams = __Maybe_Nothing;
		if (child)
		{
			__Stream_noteActivity();
			if (kind === 1)
			{
				// Node's flushStdio resumes the child's stdout / stderr when it exits, so a
				// stream nobody has started reading would drop its data. Taking the pipes out
				// of child.stdio leaves them to the channels.
				if (child.stdio)
				{
					child.stdio[1] = null;
					child.stdio[2] = null;
				}
				streams = __Maybe_Just(__Utils_Tuple3(
					__Stream_createChannelSink(__Stream_nodeWritableChannel(child.stdin)),
					__Stream_createChannelSource(__Stream_nodeReadableChannel(_ChildProcess_pipe(child.stdout))),
					__Stream_createChannelSource(__Stream_nodeReadableChannel(_ChildProcess_pipe(child.stderr)))));
			}
			child.on('error', function(e)
			{
				if (child.pid === undefined)
				{
					exit(typeof e.errno === 'number' ? e.errno : -1, 0);
				}
			});
			child.on('exit', function(code, signal)
			{
				var sig = signal ? _ChildProcess_signalNumber(signal) : 0;
				exit(code !== null ? code : 128 + sig, sig);
			});
			if (runMs > 0)
			{
				job.__timer = setTimeout(function()
				{
					job.__timer = null;
					kill();
				}, runMs);
			}
			if (kind === 3)
			{
				child.unref();
				if (job.__timer !== null) job.__timer.unref();
			}
		}
		else if (kind === 1)
		{
			streams = __Maybe_Just(__Utils_Tuple3(0, 0, 0));
		}

		var processId = __Scheduler_rawSpawn(__Scheduler_binding(function(resume)
		{
			if (job.__finished)
			{
				resume(__Scheduler_succeed(__Utils_Tuple0));
				return;
			}
			job.__resume = resume;
			return function()
			{
				job.__resume = null;
				kill();
			};
		}));

		if (failure)
		{
			// After the manager has delivered onInit (it runs in this scheduler turn).
			process.nextTick(function()
			{
				exit(typeof failure.errno === 'number' ? failure.errno : -1, 0);
			});
		}

		callback(__Scheduler_succeed(__Utils_Tuple2(processId, streams)));
	});
});
