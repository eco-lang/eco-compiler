/*
import Elm.Kernel.Utils exposing (Tuple0)
*/

// Liveness — the JS side of the program-liveness rule (plans/program-liveness-rule.md §5.2).
//
// A hold is one unit of liveness, owned by one kernel object for one reason and released
// exactly once. Natively a hold is one Scheduler pendingAsync count (HoldToken /
// LivenessHold, runtime/src/platform/Liveness.hpp); on JS it is one count of a
// _Liveness_handle / _Liveness_hold below. Node keeps the process running while a ref'd
// handle exists, so each helper keeps one Node handle ref'd exactly while at least one of
// its holds exists. JS is single-threaded: no locking.
//
// Kernels import what they need, e.g.
//   import Eco.Kernel.Liveness exposing (handle, hold)
// and call them with the double-underscore prefix (Liveness_handle, Liveness_hold).

// A Node handle (net.Server, net.Socket, dgram.Socket, http2 session socket) that is ref'd
// exactly while at least one hold on it exists. Starts unref'd: call it before or right
// after creating the handle (Node allows unref() before listen/bind).
function _Liveness_handle(h)
{
	var count = 0, reffed = true, gone = false;
	function update()
	{
		var want = count > 0 && !gone;
		if (want === reffed) return;
		reffed = want;
		try { if (want) h.ref(); else h.unref(); } catch (e) { /* destroyed */ }
	}
	update();
	return {
		hold: function()                 // -> release function, idempotent
		{
			var done = false;
			count++; update();
			return function() { if (done) return; done = true; count--; update(); };
		},
		gone: function() { gone = true; update(); },   // handle closed: never ref again
		count: function() { return count; }
	};
}

// A hold not tied to one handle: one shared keep-alive interval, ref'd while any exist.
// Returns its release function (idempotent).
var _Liveness_freeCount = 0;
var _Liveness_timer = null;
function _Liveness_hold()
{
	var done = false;
	if (_Liveness_timer === null)
	{
		_Liveness_timer = setInterval(function() {}, 1 << 30);
	}
	if (_Liveness_freeCount++ === 0) _Liveness_timer.ref();
	return function()
	{
		if (done) return;
		done = true;
		if (--_Liveness_freeCount === 0) _Liveness_timer.unref();
	};
}
