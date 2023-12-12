module libasync.internals.freelist;

import std.traits : isIntegral;

mixin template FreeList(alias Limit)
	if (is(typeof(Limit) == typeof(null)) || isIntegral!(typeof(Limit)))
{
	static if (!is(typeof(this) == struct)) static assert(false, "FreeList only works on structs");

	alias T = typeof(this);

public:
	import memutils.utils : ThreadMem;
	import std.exception : assumeWontThrow;
	static T* alloc(Args...)(auto ref Args args) @trusted
	{
		return assumeWontThrow(ThreadMem.alloc!T(args));
	}

	static void free(T* obj) @trusted
	{
		assumeWontThrow(ThreadMem.free(obj));
	}
}
mixin template UnlimitedFreeList() { mixin FreeList!null; }