#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// CPython (BeeWare's Python-Apple-support, PEP 730) started once inside the app, with the quick-add reader and the day's arrangement
/// (reader/phone_bridge.py) imported. Written after CPython's own iOS testbed. Every call blocks: not on the main thread.
@interface FingusPython : NSObject
+ (instancetype)shared;
/// One call into phone_bridge.call(name, json). Starts Python on the first call. The answer is JSON: {"ok": ...} or {"error": "..."}.
- (nullable NSString *)callName:(NSString *)name json:(NSString *)json error:(NSError **)error;
/// Seconds the first start took (Python itself, then importing the bridge); 0 before it has started.
@property (readonly) double startSeconds;
@end

NS_ASSUME_NONNULL_END
