module libasync.internals.queue;

import core.stdc.stdio : printf;

mixin template Queue()
{
	static if (!is(typeof(this) == struct)) static assert(false, "Queue only works on structs");

private:
	alias T = typeof(this);

	struct QueueRange
	{
	private:
		T* head;
		this(T* head) @safe pure @nogc
		{ this.head = head; }

	public:
		@property bool empty() const @safe pure @nogc
		{ return !head; }

		@property T* front() @safe pure @nogc
		{
			assert(!empty, T.stringof ~ ".QueueRange.front: Range is empty");
			return head;
		}

		void popFront() @safe pure @nogc
		{
			assert(!empty, T.stringof ~ ".QueueRange.popFront: Range is empty");
			head = head.queue.next;
		}

		@property typeof(this) save() @safe pure @nogc
		{ return this; }
	}

	struct QueueInfo
	{
		T* next, tail;
	}

	QueueInfo queue;

public:
	struct Queue
	{
	private:
		T* head;

	public:
		@property bool empty() const @safe pure @nogc
		{ return !head; }

		@property T* front() @safe pure @nogc
		{
			assert(!empty, T.stringof ~ ".Queue.front: Queue is empty");
			return head;
		}

		void insertFront(T* obj) @safe pure @nogc
		{
			assert(!obj.queue.next, T.stringof ~ ".Queue.insertFront: Already in a queue");
			assert(!obj.queue.tail, T.stringof ~ ".Queue.insertFront: Already head of a queue");
			if (empty) obj.queue.tail = obj;
			else {
				obj.queue.tail = head.queue.tail;
				head.queue.tail = null;
				obj.queue.next = head;
			}
			head = obj;
		}

		void removeFront() @safe pure @nogc
		{
			assert(!empty, T.stringof ~ ".Queue.removeFront: Queue is empty");
			auto newHead = head.queue.next;
			if (newHead) newHead.queue.tail = head.queue.tail;
			head.queue.next = null;
			head.queue.tail = null;
			head = newHead;
		}

		void insertBack(T* obj) @safe pure @nogc
		{
			assert(!obj.queue.next, T.stringof ~ ".Queue.insertBack: Already in a queue");
			assert(!obj.queue.tail, T.stringof ~ ".Queue.insertBack: Already head of a queue");
			if (empty) {
				obj.queue.tail = obj;
				head = obj;
			} else {
				head.queue.tail.queue.next = obj;
				head.queue.tail = obj;
			}
		}

		auto opSlice() @safe pure @nogc
		{ return QueueRange(head); }
	}
}