/*******************************************************************************

        copyright:      Copyright (c) 2008 Kris Bell. All rights reserved

        license:        BSD style: $(LICENSE)
        
        version:        Initial release: April 2008      
        
        author:         Kris

        Since:          0.99.7

*******************************************************************************/

module event.stack;

private import core.exception : RangeError;

/******************************************************************************

        A stack of the given value-type V, with maximum depth Size. Note
        that this does no memory allocation of its own when Size != 0, and
        does heap allocation when Size == 0. Thus you can have a fixed-size
        low-overhead instance, or a heap oriented instance.

******************************************************************************/

struct Stack (V, int Size = 0) 
{
	alias nth              opIndex;
	alias slice            opSlice;
	
	Stack* opOpAssign(immutable(char)[] s : ">>")(uint d)
	{
		return rotateRight(d);
	}
	
	Stack* opOpAssign(immutable(char)[] s : "<<")(uint d)
	{
		return rotateLeft(d);
	}
	
	Stack* opOpAssign(immutable(char)[] s : "~")(V value)
	{
		return push(value);
	}
	
	static if (Size == 0)
	{
		private uint depth;
		private V[]  stack;
	}
	else
	{
		private uint     depth;
		private V[Size]  stack;
	}
	
	/***********************************************************************

                Clear the stack

        ***********************************************************************/
	
	Stack* clear ()
	{
		depth = 0;
		return &this;
	}
	
	/***********************************************************************
                
                Return depth of the stack

        ***********************************************************************/
	
	@property size_t size ()
	{
		return depth;
	}
	
	/***********************************************************************
                
                Return remaining unused slots

        ***********************************************************************/
	
	size_t unused ()
	{
		return stack.length - depth;
	}
	
	/***********************************************************************
                
                Returns a (shallow) clone of this stack, on the stack

        ***********************************************************************/
	
	Stack clone ()
	{       
		Stack s = void;
		static if (Size == 0)
			s.stack.length = stack.length;
		s.stack[] = stack[];
		s.depth = depth;
		return s;
	}
	
	/***********************************************************************
                
                Push and return a (shallow) copy of the topmost element

        ***********************************************************************/
	
	@property V dup ()
	{
		auto v = top;
		push (v);       
		return v;
	}
	
	/**********************************************************************

                Push a value onto the stack.

                Throws an exception when the stack is full

        **********************************************************************/
	
	Stack* push (V value)
	{
		static if (Size == 0)
		{
			if (depth >= stack.length)
				stack.length = stack.length + 64;
			stack[depth++] = value;
		}
		else
		{                         
			if (depth < stack.length)
				stack[depth++] = value;
			else
				error (__LINE__);
		}
		return &this;
	}
	
	/**********************************************************************

                Push a series of values onto the stack.

                Throws an exception when the stack is full

        **********************************************************************/
	
	Stack* append (V[] value...)
	{
		foreach (v; value)
			push (v);
		return &this;
	}
	
	/**********************************************************************

                Remove and return the most recent addition to the stack.

                Throws an exception when the stack is empty

        **********************************************************************/
	
	V pop ()
	{
		if (depth)
			return stack[--depth];
		
		return error (__LINE__);
	}
	
	/**********************************************************************

                Return the most recent addition to the stack.

                Throws an exception when the stack is empty

        **********************************************************************/
	
	@property V top ()
	{
		if (depth)
			return stack[depth-1];
		
		return error (__LINE__);
	}
	
	/**********************************************************************

                Swaps the top two entries, and return the top

                Throws an exception when the stack has insufficient entries

        **********************************************************************/
	
	V swap ()
	{
		auto p = stack.ptr + depth;
		if ((p -= 2) >= stack.ptr)
		{
			auto v = p[0];
			p[0] = p[1];
			return p[1] = v; 
		}
		
		return error (__LINE__);                
	}
	
	/**********************************************************************

                Index stack entries, where a zero index represents the
                newest stack entry (the top).

                Throws an exception when the given index is out of range

        **********************************************************************/
	
	V nth (size_t i)
	{
		if (i < depth)
			return stack [depth-i-1];
		
		return error (__LINE__);
	}
	
	/**********************************************************************

                Rotate the given number of stack entries 

                Throws an exception when the number is out of range

        **********************************************************************/
	
	Stack* rotateLeft (size_t d)
	{
		if (d <= depth)
		{
			auto p = &stack[depth-d];
			auto t = *p;
			while (--d)
				*p++ = *(p+1);
			*p = t;
		}
		else
			error (__LINE__);
		return &this;
	}
	
	/**********************************************************************

                Rotate the given number of stack entries 

                Throws an exception when the number is out of range

        **********************************************************************/
	
	Stack* rotateRight (size_t d)
	{
		if (d <= depth)
		{
			auto p = &stack[depth-1];
			auto t = *p;
			while (--d)
				*p-- = *(p-1);
			*p = t;
		}
		else
			error (__LINE__);
		return &this;
	}
	
	/**********************************************************************

                Return the stack as an array of values, where the first
                array entry represents the oldest value. 
                
                Doing a foreach() on the returned array will traverse in
                the opposite direction of foreach() upon a stack
                 
        **********************************************************************/
	
	V[] slice ()
	{
		return stack [0 .. depth];
	}
	
	/**********************************************************************

                Throw an exception 

        **********************************************************************/
	
	private V error (size_t line)
	{
		throw new RangeError (__FILE__, line);
	}
	
	/***********************************************************************

                Iterate from the most recent to the oldest stack entries

        ***********************************************************************/
	
	int opApply (scope int delegate(ref V value) dg)
	{
		int result;
		
		for (int i=depth; i-- && result is 0;)
			result = dg (stack[i]);
		return result;
	}
}


/*******************************************************************************

*******************************************************************************/

debug (Stack)
{
	import tango.io.Stdout;
	
	void main()
	{
		Stack!(int) v;
		v.push(1);
		
		Stack!(int, 10) s;
		
		Stdout.formatln ("push four");
		s.push (1);
		s.push (2);
		s.push (3);
		s.push (4);
		foreach (v; s)
			Stdout.formatln ("{}", v);
		s <<= 4;
		s >>= 4;
		foreach (v; s)
			Stdout.formatln ("{}", v);
		
		s = s.clone;
		Stdout.formatln ("pop one: {}", s.pop);
		foreach (v; s)
			Stdout.formatln ("{}", v);
		Stdout.formatln ("top: {}", s.top);
		
		Stdout.formatln ("pop three");
		s.pop;
		s.pop;
		s.pop;
		foreach (v; s)
			Stdout.formatln ("> {}", v);
	}
}
