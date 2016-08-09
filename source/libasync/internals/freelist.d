module libasync.internals.freelist;

import std.traits : isIntegral;

mixin template FreeList(alias Limit)
	if (is(typeof(Limit) == typeof(null)) || isIntegral!(typeof(Limit)))
{
	static if (!is(typeof(this) == struct)) static assert(false, "FreeList only works on structs");

private:
	alias T = typeof(this);

	struct FreeListInfo
	{
		/// Head element in the freelist of previously allocated elements.
		static T* head;
		/// Current number of elements in the freelist
		static if (isIntegral!(typeof(Limit))) {
			static typeof(Limit) count;
		} else {
			static size_t count;
		}
		/// Next element in the freelist, if this element is on it.
		T* next;
	}
	FreeListInfo freelist;

public:
	import std.exception : assumeWontThrow;
	import std.traits : isIntegral;
	import std.conv : emplace;

	import memutils.utils : ThreadMem;

	static T* alloc(Args...)(auto ref Args args) @trusted
	{
		T* obj = void;

		// If a previously allocated instance is available,
		// pull it from the freelist and return it.
		if (freelist.head) {
			obj = freelist.head;
			freelist.head = obj.freelist.next;
			freelist.count -= 1;
			static if (Args.length > 0) {
				emplace!(T)(obj, args);
			}
			.tracef(T.stringof ~ ".FreeList.alloc: Pulled %s", obj);
		// Otherwise, allocate a new instance.
		} else {
			obj = assumeWontThrow(ThreadMem.alloc!T(args));
			.tracef(T.stringof ~ ".FreeList.alloc: Allocated %s", obj);
		}

		return obj;
	}

	static void free(T* obj) @trusted
	{
		static if (isIntegral!(typeof(Limit))) {
			if (freelist.count <= Limit / T.sizeof) {
				obj.freelist.next = freelist.head;
				freelist.head = obj;
				freelist.count += 1;
				.tracef(T.stringof ~ ".FreeList.free: Pushed %s", obj);
			} else {
				.tracef(T.stringof ~ ".FreeList.free: Deallocating %s", obj);
				ThreadMem.free(obj);
			}
		} else {
			obj.freelist.next = freelist.head;
			freelist.head = obj;
			freelist.count += 1;
			.tracef(T.stringof ~ ".FreeList.free: Pushed %s", obj);
		}
	}
}
mixin template UnlimitedFreeList() { mixin FreeList!null; }