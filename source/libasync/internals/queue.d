module libasync.internals.queue;

mixin template Queue()
{
	static if (!is(typeof(this) == struct)) static assert(false, "Queue only works on structs");

private:
	alias T = typeof(this);

	/**
	 * Iterates over the elements in the queue at the time of the range's creation.
	 * The range is safe from being invalidated by the following queue mutating operations:
	 *  - any number of insertFront
	 *  - any number of insertBack
	 *  - a single removeFront beyond the current element of the range
	 * Removing more than one element from the queue the range is iterating over beyond
	 * the current element of the range results in undefined behaviour.
	 */
	struct QueueRange
	{
	private:
		T* head, tail, next;

		this(T* head) @safe pure @nogc nothrow
		{
			if (head) {
				assert(head.queue.tail, T.stringof ~ ".QueueRange.this: Not head of a queue");
				this.head = head;
				tail = this.head.queue.tail;
				next = this.head.queue.next;
			}
		}

	public:
		@property bool empty() const @safe pure @nogc nothrow
		{ return !head; }

		@property T* front() @safe pure @nogc nothrow
		{
			assert(!empty, T.stringof ~ ".QueueRange.front: Range is empty");
			return head;
		}

		void popFront() @safe pure @nogc nothrow
		{
			assert(!empty, T.stringof ~ ".QueueRange.popFront: Range is empty");
			head = next;
			if (!empty && head != tail) next = head.queue.next;
			else next = null;
		}

		@property typeof(this) save() @safe pure @nogc nothrow
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
		@property bool empty() const @safe pure @nogc nothrow
		{ return !head; }

		@property T* front() @safe pure @nogc nothrow
		{
			assert(!empty, T.stringof ~ ".Queue.front: Queue is empty");
			return head;
		}

		void insertFront(T* obj) @safe pure /+@nogc+/ nothrow
		{
			assert(obj, T.stringof ~ ".Queue.insertFront: Null elements are forbidden");
			assert(!obj.queue.next, T.stringof ~ ".Queue.insertFront: Already in a queue");
			assert(head != obj, T.stringof ~ ".Queue.insertBack: Already head of this queue");
			assert(!obj.queue.tail, T.stringof ~ ".Queue.insertFront: Already head of a queue");
			if (empty) obj.queue.tail = obj;
			else {
				obj.queue.tail = head.queue.tail;
				head.queue.tail = null;
				obj.queue.next = head;
			}
			head = obj;
			debug .tracef(T.stringof ~ ".Queue.insertFront: Inserted %s", obj);
		}

		void removeFront() @safe pure /+@nogc+/ nothrow
		{
			assert(!empty, T.stringof ~ ".Queue.removeFront: Queue is empty");
			debug .tracef(T.stringof ~ ".Queue.removeFront: Removing %s", head);
			auto newHead = head.queue.next;
			if (newHead) newHead.queue.tail = head.queue.tail;
			head.queue.next = null;
			head.queue.tail = null;
			head = newHead;
		}

		void insertBack(T* obj) @safe pure /+@nogc+/ nothrow
		{
			assert(obj, T.stringof ~ ".Queue.insertBack: Null elements are forbidden");
			assert(!obj.queue.next, T.stringof ~ ".Queue.insertBack: Already in a queue");
			assert(!obj.queue.tail, T.stringof ~ ".Queue.insertBack: Already head of a queue");
			assert(head != obj, T.stringof ~ ".Queue.insertBack: Duplicate elements are forbidden");
			if (empty) {
				obj.queue.tail = obj;
				head = obj;
			} else {
				head.queue.tail.queue.next = obj;
				head.queue.tail = obj;
			}
			debug .tracef(T.stringof ~ ".Queue.insertBack: Inserted %s", obj);
		}

		auto opSlice() @safe pure @nogc nothrow
		{ return QueueRange(head); }
	}
}