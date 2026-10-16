// ReaderTry: starts CPython inside the app, runs reader/run_lines.py over reader/lines.json, writes the readings and the timings
// to the app's Documents folder, and exits. It shows nothing but a label. Written after CPython's own iOS testbed (Apple/testbed).
#import <UIKit/UIKit.h>
#include <Python/Python.h>
#include <time.h>

static double now_s(void) { return (double)clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1e9; }

static int fail(PyStatus st, PyConfig *config, const char *what) {
    fprintf(stderr, "READERTRY FAIL %s: %s\n", what, st.err_msg ? st.err_msg : "(no message)");
    if (config) PyConfig_Clear(config);
    return 1;
}

static int add_path(PyConfig *config, NSString *dir) {
    wchar_t *w = Py_DecodeLocale([dir UTF8String], NULL);
    PyStatus st = PyWideStringList_Append(&config->module_search_paths, w);
    PyMem_RawFree(w);
    if (PyStatus_Exception(st)) return fail(st, config, "append path");
    return 0;
}

static int run(void) {
    NSString *bundle = [[NSBundle mainBundle] resourcePath];
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
    NSString *home = [bundle stringByAppendingPathComponent:@"python"];
    NSString *lib = [home stringByAppendingPathComponent:@"lib/python3.13"];

    double t0 = now_s();
    PyPreConfig pre;
    PyPreConfig_InitIsolatedConfig(&pre);
    pre.utf8_mode = 1;
    PyStatus st = Py_PreInitialize(&pre);
    if (PyStatus_Exception(st)) return fail(st, NULL, "preinit");

    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.buffered_stdio = 0;
    config.write_bytecode = 0;
    config.install_signal_handlers = 0;
    st = PyConfig_SetBytesString(&config, &config.home, [home UTF8String]);
    if (PyStatus_Exception(st)) return fail(st, &config, "home");
    config.module_search_paths_set = 1;
    if (add_path(&config, lib)) return 1;
    if (add_path(&config, [lib stringByAppendingPathComponent:@"lib-dynload"])) return 1;
    if (add_path(&config, [bundle stringByAppendingPathComponent:@"app_packages"])) return 1;
    if (add_path(&config, [bundle stringByAppendingPathComponent:@"reader"])) return 1;
    st = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(st)) return fail(st, NULL, "initialize");
    double t_init = now_s() - t0;

    NSString *out = [docs stringByAppendingPathComponent:@"readings.json"];
    NSString *script = [NSString stringWithFormat:
        @"import sys, runpy\nsys.argv = ['run_lines', %@]\nrunpy.run_path(%@, run_name='__main__')\n",
        [NSString stringWithFormat:@"'%@'", out],
        [NSString stringWithFormat:@"'%@'", [[bundle stringByAppendingPathComponent:@"reader"] stringByAppendingPathComponent:@"run_lines.py"]]];
    int rc = PyRun_SimpleString([script UTF8String]);
    double t_total = now_s() - t0;

    NSDictionary *info = @{@"python_init_s": @(t_init), @"init_plus_run_s": @(t_total), @"python_rc": @(rc)};
    NSData *d = [NSJSONSerialization dataWithJSONObject:info options:NSJSONWritingPrettyPrinted error:nil];
    [d writeToFile:[docs stringByAppendingPathComponent:@"init.json"] atomically:YES];
    printf("READERTRY done rc=%d init=%.3fs total=%.3fs\n", rc, t_init, t_total);
    return rc;
}

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong) UIWindow *window;
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = UIColor.whiteColor;
    UILabel *l = [[UILabel alloc] initWithFrame:vc.view.bounds];
    l.text = @"ReaderTry";
    l.textAlignment = NSTextAlignmentCenter;
    [vc.view addSubview:l];
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];
    dispatch_async(dispatch_get_main_queue(), ^{
        int rc = run();
        fflush(stdout);
        exit(rc);
    });
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
