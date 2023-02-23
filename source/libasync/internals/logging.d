module libasync.internals.logging;

import libasync.types;
static if (__VERSION__ < 2103){
    import std.experimental.logger;
}
else {
    import std.logger;
}

nothrow:
// The below is adapted for nothrow from
// https://github.com/dlang/phobos/blob/master/std/experimental/logger/core.d
// and is thus under Boost license

template defaultLogFunction(LogLevel ll)
{
    void defaultLogFunction(int line = __LINE__, string file = __FILE__,
        string funcName = __FUNCTION__,
        string prettyFuncName = __PRETTY_FUNCTION__,
        string moduleName = __MODULE__, A...)(lazy A args) @trusted
        if ((args.length > 0 && !is(Unqual!(A[0]) : bool)) || args.length == 0)
    {
        static if (ll >= LOGLEVEL)
        {
            try stdThreadLocalLog.log!(line, file, funcName, prettyFuncName, moduleName)("", args);
            catch (Throwable e) {}
        }
    }

    void defaultLogFunction(int line = __LINE__, string file = __FILE__,
        string funcName = __FUNCTION__,
        string prettyFuncName = __PRETTY_FUNCTION__,
        string moduleName = __MODULE__, A...)(lazy bool condition, lazy A args) @trusted
    {
        static if (ll >= LOGLEVEL)
        {
            try log!(line, file, funcName, prettyFuncName, moduleName)(condition, args);
            catch (Throwable e) {}
        }
    }
}

alias trace = defaultLogFunction!(LogLevel.trace);
alias info = defaultLogFunction!(LogLevel.info);
alias warning = defaultLogFunction!(LogLevel.warning);
alias error = defaultLogFunction!(LogLevel.error);
alias critical = defaultLogFunction!(LogLevel.critical);

template defaultLogFunctionf(LogLevel ll)
{
    void defaultLogFunctionf(int line = __LINE__, string file = __FILE__,
        string funcName = __FUNCTION__,
        string prettyFuncName = __PRETTY_FUNCTION__,
        string moduleName = __MODULE__, A...)(lazy string msg, lazy A args) @trusted
    {
        static if (ll >= LOGLEVEL)
        {
            try logf!(line, file, funcName, prettyFuncName, moduleName)(msg, args);
            catch (Throwable e) {}
        }
    }

    void defaultLogFunctionf(int line = __LINE__, string file = __FILE__,
        string funcName = __FUNCTION__,
        string prettyFuncName = __PRETTY_FUNCTION__,
        string moduleName = __MODULE__, A...)(lazy bool condition, lazy string msg, lazy A args) @trusted
    {
        static if (ll >= LOGLEVEL)
        {
            try logf!(line, file, funcName, prettyFuncName, moduleName)(condition, msg, args);
            catch (Throwable e) {}
        }
    }
}

alias tracef = defaultLogFunctionf!(LogLevel.trace);
alias infof = defaultLogFunctionf!(LogLevel.info);
alias warningf = defaultLogFunctionf!(LogLevel.warning);
alias errorf = defaultLogFunctionf!(LogLevel.error);
alias criticalf = defaultLogFunctionf!(LogLevel.critical);