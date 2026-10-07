/*
import Elm.Kernel.Scheduler exposing (binding, succeed, rawSpawn)
import Elm.Kernel.Utils exposing (Tuple0, Tuple2, Tuple3)
import Elm.Kernel.List exposing (fromArray)
import Eco.Kernel.Stream exposing (createChannelSource, createChannelSink, nodeReadableChannel, nodeWritableChannel, pin, activityCount)
*/

// System — JS twin of src/eco-system/System/ (eco/system), plans/eco-system-library.md
// Appendix B.1, §3.7, Phase 10 (decision D15).
//
// The B.1 kernels return exactly the native shapes. The three `attach*` kernels at the end
// are JS-only: they are used by the Elm effect-manager bodies in System.elm, which only
// the JS backend runs (the native backend drops them and uses the C++ manager, C.1).


// --- Standard streams (created once per process, pinned) --------------------------

var _System_stdioIds = null;

function _System_stdio()
{
	if (!_System_stdioIds)
	{
		// stdin is resolved lazily (on the first read), so a program that never reads
		// it does not touch process.stdin. fds 0-2 are never closed (keepOpen).
		var stdin = __Stream_createChannelSource(__Stream_nodeReadableChannel(
			function() { return process.stdin; }, { keepOpen: true }));
		var stdout = __Stream_createChannelSink(__Stream_nodeWritableChannel(
			function() { return process.stdout; }, { keepOpen: true }));
		var stderr = __Stream_createChannelSink(__Stream_nodeWritableChannel(
			function() { return process.stderr; }, { keepOpen: true }));
		__Stream_pin(stdin);
		__Stream_pin(stdout);
		__Stream_pin(stderr);
		_System_stdioIds = { __stdin: stdin, __stdout: stdout, __stderr: stderr };
	}
	return _System_stdioIds;
}

// The real path of the running program: the compiled module's file when it is loaded as
// a CommonJS module, otherwise the node executable.
function _System_applicationPath()
{
	var p = (typeof module !== 'undefined' && module && module.filename) ? module.filename : process.execPath;
	try
	{
		return require('fs').realpathSync(p);
	}
	catch (e)
	{
		return p;
	}
}


// --- B.1 -------------------------------------------------------------------------------

// environment : Task Never ( ( String, String, String ), List String, ( Int, Int, Int ) )
// argv: process.argv without the node binary, so args[0] is the program (the script) as
// invoked, as on the native target (D10).
var _System_environment = __Scheduler_binding(function(callback)
{
	var ids = _System_stdio();
	callback(__Scheduler_succeed(__Utils_Tuple3(
		__Utils_Tuple3(process.platform, process.arch, _System_applicationPath()),
		__List_fromArray(process.argv.slice(1)),
		__Utils_Tuple3(ids.__stdin, ids.__stdout, ids.__stderr)
	)));
});

var _System_getPlatform = __Scheduler_binding(function(callback)
{
	callback(__Scheduler_succeed(process.platform));
});

var _System_getCpuArchitecture = __Scheduler_binding(function(callback)
{
	callback(__Scheduler_succeed(process.arch));
});

// getEnvironmentVariables : Task Never (List ( String, String ))
var _System_getEnvironmentVariables = __Scheduler_binding(function(callback)
{
	var pairs = [];
	for (var key in process.env)
	{
		pairs.push(__Utils_Tuple2(key, process.env[key]));
	}
	callback(__Scheduler_succeed(__List_fromArray(pairs)));
});

// exitWithCode : Int -> Task Never () — ends the process at once (§3.7); pending IO is not
// waited for.
var _System_exitWithCode = function(code)
{
	return __Scheduler_binding(function(callback)
	{
		process.exit(code);
	});
};

// setExitCode : Int -> Task Never ()
var _System_setExitCode = function(code)
{
	return __Scheduler_binding(function(callback)
	{
		process.exitCode = code;
		callback(__Scheduler_succeed(__Utils_Tuple0));
	});
};


// --- JS-only: listeners for the Elm System manager ---------------------------------------
//
// Each is a binding that never completes; killing its process (Process.kill) detaches the
// listener. On every event it spawns `task` (a Platform.sendToSelf).

// onEmptyEventLoop (§3.7, Node 'beforeExit'): fires when the program runs out of work, then
// re-arms only once external IO has been started since it last fired (a Stream channel
// request, or a kernel calling Stream's noteActivity), as the native hook re-arms on
// incrementPendingAsync. After firing it keeps the loop alive for one more turn, so IO
// that completed synchronously (a stdout write) still leads to a second check.
var _System_attachEmptyEventLoopListener = function(task)
{
	return __Scheduler_binding(function(callback)
	{
		var lastSeen = -1;
		var listener = function()
		{
			var now = __Stream_activityCount();
			if (now === lastSeen)
			{
				return;
			}
			lastSeen = now;
			__Scheduler_rawSpawn(task);
			setImmediate(function() {});
		};
		process.on('beforeExit', listener);
		return function()
		{
			process.removeListener('beforeExit', listener);
		};
	});
};

// onSignalInterrupt / onSignalTerminate: `signal` is "SIGINT" or "SIGTERM". While the
// listener is attached the signal no longer terminates the process. Signal listeners do
// not keep the process alive (§3.4).
var _System_attachSignalListener = F2(function(signal, task)
{
	return __Scheduler_binding(function(callback)
	{
		var listener = function()
		{
			__Scheduler_rawSpawn(task);
		};
		process.on(signal, listener);
		return function()
		{
			process.removeListener(signal, listener);
		};
	});
});
