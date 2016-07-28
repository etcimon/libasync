module libasync.internals.freelist;

import std.traits : isIntegral;

import core.stdc.stdio : printf;

mixin template FreeList(alias Limit)
	if (is(typeof(Limit) == typeof(null)) || isIntegral!(typeof(Limit)))
{
public:
	import std.exception : assumeWontThrow;
	import std.algorithm : fill;
	import std.traits : isIntegral;
	import std.conv : emplace;

	import memutils.utils : ThreadMem;

	static typeof(this)* alloc(Args...)(auto ref Args args) @trusted nothrow
	{
		typeof(this)* obj = void;

		// If a previously allocated instance is available,
		// pull it from the freelist and return it.
		if (freelist.head) {
			printf("Pulling from freelist\n");
			obj = freelist.head;
			freelist.head = obj.freelist.next;
			freelist.count -= 1;
			static if (Args.length > 0) {
				emplace!(typeof(this))(obj, args);
			}
		// Otherwise, allocate a new instance.
		} else {
			printf("Allocating\n");
			obj = assumeWontThrow(ThreadMem.alloc!(typeof(this))(args));
		}

		return obj;
	}

	static void free(typeof(this)* obj) @trusted nothrow
	{
		static if (isIntegral!(typeof(Limit))) {
			if (freelist.count <= Limit) {
				printf("Putting on freelist\n");
				obj.freelist.next = freelist.head;
				freelist.head = obj;
				freelist.count += 1;
			} else {
				printf("Deallocating\n");
				assumeWontThrow(ThreadMem.free(obj));
			}
		} else {
			printf("Putting on freelist\n");
			obj.freelist.next = freelist.head;
			freelist.head = obj;
			freelist.count += 1;
		}
	}

private:

	struct FreeListInfo(T)
	{
		/// Head element in the freelist of previously allocated elements.
		static T* head;
		/// Current number of elements in the freelist
		static if (isIntegral!(typeof(Limit))) {
			static typeof(Limit) count;
		} else {
			static size_t count;
		}
		T* next;
	}
	static FreeListInfo!(typeof(this)) freelist;
}
mixin template UnlimitedFreeList() { mixin FreeList!null; }