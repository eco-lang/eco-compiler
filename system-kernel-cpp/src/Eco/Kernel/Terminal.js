/*
import Elm.Kernel.Scheduler exposing (binding, succeed, rawSpawn)
import Elm.Kernel.Utils exposing (Tuple0, Tuple2, Tuple3)
import Maybe exposing (Just, Nothing)
*/

// Terminal — JS twin of src/eco-system/Terminal/ (eco/system), plans/eco-system-library.md
// Appendix B.5, C.4, §3.8, Phase 5 step 5.3, Phase 10 (D15).
//
//   * getConfiguration — Nothing unless stdout (fd 1) is a terminal; otherwise
//     ( colorDepth, columns, rows ). The size comes from the first terminal among
//     stdout and stderr (native: fds 1, 0, 2; Node cannot size fd 0 without opening a
//     second stream on it). The colour depth is the B.5 heuristic, as native (not
//     Node's getColorDepth, which also looks at CI variables and TERM tables).
//   * setStdInRawMode — process.stdin.setRawMode when fd 0 is a terminal, otherwise a
//     no-op. Node itself restores the terminal at exit and when SIGINT / SIGTERM end
//     the process (its ResetStdio), which is the native atexit + signal-listener rule.
//   * setProcessTitle — process.title (Linux: libuv sets the command line and, through
//     PR_SET_NAME, the main thread's `comm`, at most 15 bytes, as native).
//
// `attachResizeListener` is JS-only: the Elm System.Terminal manager body uses it (the
// native backend runs the C++ manager, C.4).

function _Terminal_isatty(fd)
{
	try
	{
		return require('tty').isatty(fd);
	}
	catch (e)
	{
		return false;
	}
}

// [ columns, rows ] of the first terminal among stdout and stderr, or null.
function _Terminal_size()
{
	var fds = [1, 2];
	for (var i = 0; i < fds.length; i++)
	{
		if (!_Terminal_isatty(fds[i])) continue;
		var s = fds[i] === 1 ? process.stdout : process.stderr;
		if (s && typeof s.getWindowSize === 'function')
		{
			try
			{
				var size = s.getWindowSize();
				if (size && size[0] > 0) return size;
			}
			catch (e)
			{
			}
		}
	}
	return null;
}

// B.5: NO_COLOR or TERM=dumb → 1; FORCE_COLOR=0/1/2/3 → 1/4/8/24; COLORTERM truecolor or
// 24bit → 24; TERM ending in 256color → 8; otherwise 4.
function _Terminal_colorDepth()
{
	var env = process.env;
	var term = env.TERM || '';
	if (env.NO_COLOR) return 1;
	if (term === 'dumb') return 1;
	var force = env.FORCE_COLOR;
	if (force === '0') return 1;
	if (force === '1') return 4;
	if (force === '2') return 8;
	if (force === '3') return 24;
	var colorterm = env.COLORTERM;
	if (colorterm === 'truecolor' || colorterm === '24bit') return 24;
	if (term.length >= 8 && term.slice(-8) === '256color') return 8;
	return 4;
}


// --- B.5 -------------------------------------------------------------------------------

// getConfiguration : Task Never (Maybe ( Int, Int, Int ))
var _Terminal_getConfiguration = __Scheduler_binding(function(callback)
{
	if (!_Terminal_isatty(1))
	{
		callback(__Scheduler_succeed(__Maybe_Nothing));
		return;
	}
	var size = _Terminal_size() || [0, 0];
	callback(__Scheduler_succeed(__Maybe_Just(__Utils_Tuple3(_Terminal_colorDepth(), size[0], size[1]))));
});

// setStdInRawMode : Bool -> Task Never ()
var _Terminal_setStdInRawMode = function(on)
{
	return __Scheduler_binding(function(callback)
	{
		if (_Terminal_isatty(0) && process.stdin && typeof process.stdin.setRawMode === 'function')
		{
			try
			{
				process.stdin.setRawMode(on);
			}
			catch (e)
			{
			}
		}
		callback(__Scheduler_succeed(__Utils_Tuple0));
	});
};

// setProcessTitle : String -> Task Never ()
var _Terminal_setProcessTitle = function(title)
{
	return __Scheduler_binding(function(callback)
	{
		try
		{
			process.title = title;
		}
		catch (e)
		{
		}
		callback(__Scheduler_succeed(__Utils_Tuple0));
	});
};


// --- JS-only: the resize listener of the Elm System.Terminal manager (C.4) ------------
//
// attachResizeListener : (( Int, Int ) -> Task Never ()) -> Task Never ()
// A binding that never completes; killing its process detaches the listener. On every
// SIGWINCH it spawns `notify ( columns, rows )`; nothing is delivered while no stdio fd
// is a terminal (as native, and Node's stdout 'resize'). Node's signal handles are
// unref'd, so the listener does not keep the program alive (§3.4).
var _Terminal_attachResizeListener = function(notify)
{
	return __Scheduler_binding(function(callback)
	{
		var listener = function()
		{
			var size = _Terminal_size();
			if (size)
			{
				__Scheduler_rawSpawn(notify(__Utils_Tuple2(size[0], size[1])));
			}
		};
		process.on('SIGWINCH', listener);
		return function()
		{
			process.removeListener('SIGWINCH', listener);
		};
	});
};
