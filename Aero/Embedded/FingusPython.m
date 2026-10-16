#import "FingusPython.h"
#include <Python/Python.h>
#include <time.h>

static double now_s(void) { return (double)clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1e9; }

static NSError *fail(NSString *what) {
    return [NSError errorWithDomain:@"FingusPython" code:1 userInfo:@{NSLocalizedDescriptionKey: what}];
}

@implementation FingusPython {
    PyObject *_bridgeCall;      // phone_bridge.call
    BOOL _started;
    NSError *_startError;
    double _startSeconds;
}

+ (instancetype)shared {
    static FingusPython *one;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ one = [FingusPython new]; });
    return one;
}

- (double)startSeconds { return _startSeconds; }

- (NSError *)status:(PyStatus)st what:(NSString *)what {
    return fail([NSString stringWithFormat:@"%@: %s", what, st.err_msg ? st.err_msg : "(no message)"]);
}

static int add_path(PyConfig *config, NSString *dir, PyStatus *st) {
    wchar_t *w = Py_DecodeLocale([dir UTF8String], NULL);
    *st = PyWideStringList_Append(&config->module_search_paths, w);
    PyMem_RawFree(w);
    return PyStatus_Exception(*st) ? 1 : 0;
}

/// Starts Python (once) and imports the bridge. Called with @synchronized(self).
- (NSError *)startLocked {
    if (_started) return _startError;
    _started = YES;
    double t0 = now_s();
    NSString *bundle = [[NSBundle mainBundle] resourcePath];
    NSString *home = [bundle stringByAppendingPathComponent:@"python"];
    NSString *lib = [home stringByAppendingPathComponent:@"lib/python3.13"];

    PyPreConfig pre;
    PyPreConfig_InitIsolatedConfig(&pre);
    pre.utf8_mode = 1;
    PyStatus st = Py_PreInitialize(&pre);
    if (PyStatus_Exception(st)) return _startError = [self status:st what:@"preinit"];

    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.buffered_stdio = 0;
    config.write_bytecode = 0;
    config.install_signal_handlers = 0;
    st = PyConfig_SetBytesString(&config, &config.home, [home UTF8String]);
    if (PyStatus_Exception(st)) { PyConfig_Clear(&config); return _startError = [self status:st what:@"home"]; }
    config.module_search_paths_set = 1;
    NSArray<NSString *> *paths = @[lib, [lib stringByAppendingPathComponent:@"lib-dynload"],
                                   [bundle stringByAppendingPathComponent:@"app_packages"], [bundle stringByAppendingPathComponent:@"reader"]];
    for (NSString *p in paths) {
        if (add_path(&config, p, &st)) { PyConfig_Clear(&config); return _startError = [self status:st what:@"path"]; }
    }
    st = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(st)) return _startError = [self status:st what:@"initialize"];

    PyObject *mod = PyImport_ImportModule("phone_bridge");
    if (!mod) {
        PyErr_Print();
        PyEval_SaveThread();
        return _startError = fail(@"phone_bridge could not be imported");
    }
    _bridgeCall = PyObject_GetAttrString(mod, "call");
    Py_DECREF(mod);
    // the thread that started Python holds the GIL; give it up so any thread can take it per call
    PyEval_SaveThread();
    _startSeconds = now_s() - t0;
    if (!_bridgeCall) return _startError = fail(@"phone_bridge has no call()");
    return nil;
}

- (NSString *)callName:(NSString *)name json:(NSString *)json error:(NSError **)error {
    NSError *started;
    @synchronized (self) { started = [self startLocked]; }
    if (started) { if (error) *error = started; return nil; }
    PyGILState_STATE g = PyGILState_Ensure();
    NSString *result = nil;
    PyObject *out = PyObject_CallFunction(_bridgeCall, "ss", [name UTF8String], [json UTF8String]);
    if (out) {
        const char *c = PyUnicode_AsUTF8(out);
        if (c) result = [NSString stringWithUTF8String:c];
        Py_DECREF(out);
    } else {
        PyErr_Print();
    }
    PyGILState_Release(g);
    if (!result && error) *error = fail(@"the reader did not answer");
    return result;
}

@end
