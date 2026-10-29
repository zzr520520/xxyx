#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreMotion/CoreMotion.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

static CFAbsoluteTime kAppStartTimestamp = 0;

// ============================================================================
// 1. 全量广告域名黑名单 (保持三方广告 100% 零请求)
// ============================================================================
static NSString * const kBlockedAdHosts[] = {
    @"leadmoad.com", @"adbiding.com", @"tobidad.cn", @"tobidad.com",
    @"sigmob.cn", @"pangolin-sdk-toutiao", @"pglstatp-toutiao.com",
    @"ctobsnssdk.com", @"oceanengine.com", @"bdurl.net", @"bytescm.com",
    @"bytegoofy.com", @"volces.com", @"zijieapi.com", @"douyin.com",
    @"douyinstatic.com", @"gdt.qq.com", @"e.qq.com", @"ugdtimg.com",
    @"gdtimg.com", @"mobads.baidu.com", @"als.baidu.com", @"pos.baidu.com",
    @"beizi.biz", @"adn-plus.com.cn", @"ad-scope.com.cn", @"mentamob.com",
    @"advlion.com", @"vlion.cn", @"fibo.cn", @"fancydsp.com", @"fancyapi.com",
    @"dmrtb.com", @"richmob.cn", @"ubixioe.com", @"tanx.com", @"1rtb.net",
    @"1rtb.com", @"yunxish.com", @"58iclick.com", @"iggrowth.cn",
    @"innotechx.com", @"etoolads.cn", @"zhangyuyidong.cn", @"hubcloud.com.cn",
    @"nwiztech.com", @"kuaishou.com", @"gifshow.com",
    @"iadsdk.apple.com", @"adservices.apple.com"
};

static const size_t kBlockedAdHostsCount = sizeof(kBlockedAdHosts) / sizeof(kBlockedAdHosts[0]);

static BOOL shouldBlockAdURL(NSURL *url) {
    if (!url || ![url isKindOfClass:[NSURL class]]) return NO;
    NSString *host = [url host];
    if (!host || ![host isKindOfClass:[NSString class]] || host.length == 0) return NO;
    
    NSString *lowerHost = [host lowercaseString];
    if ([lowerHost containsString:@"xiaocantech.com"] ||
        [lowerHost containsString:@"realtech-inc.com"] ||
        [lowerHost containsString:@"xinyifm.cn"] ||
        [lowerHost containsString:@"hzaiguojiang.com"] ||
        [lowerHost containsString:@"djtaoke.cn"] ||
        [lowerHost containsString:@"fengkongcloud.com"] ||
        [lowerHost containsString:@"qlogo.cn"] ||
        [lowerHost containsString:@"map.qq.com"] ||
        [lowerHost containsString:@"connect.qq.com"]) {
        return NO;
    }
    
    for (size_t i = 0; i < kBlockedAdHostsCount; i++) {
        if ([lowerHost containsString:kBlockedAdHosts[i]]) {
            return YES;
        }
    }
    return NO;
}

static BOOL isXiaoCanAdPlacementRPC(NSURLRequest *request) {
    if (!request || !request.URL) return NO;
    NSString *absURL = [request.URL.absoluteString lowercaseString];
    if (![absURL containsString:@"gw.xiaocantech.com/rpc"]) return NO;
    
    NSString *methodName = [request valueForHTTPHeaderField:@"methodname"];
    NSString *serverName = [request valueForHTTPHeaderField:@"servername"];
    
    if (methodName && ([methodName containsString:@"MatchPlacement"] || [methodName containsString:@"AdMobileService"])) {
        return YES;
    }
    if (serverName && [serverName isEqualToString:@"SilkwormAd"]) {
        return YES;
    }
    return NO;
}

// ============================================================================
// 2. 协议层秒回伪造数据 (彻底封死 AdMobileService 与 20+ 家三方 SDK)
// ============================================================================
@interface XCSuperAdBlockProtocol : NSURLProtocol
@end

@implementation XCSuperAdBlockProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if ([NSURLProtocol propertyForKey:@"XCSuperAdHandled" inRequest:request]) {
        return NO;
    }
    if (isXiaoCanAdPlacementRPC(request) || shouldBlockAdURL(request.URL)) {
        return YES;
    }
    return NO;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSMutableURLRequest *mutableReq = [self.request mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:@"XCSuperAdHandled" inRequest:mutableReq];
    
    if (isXiaoCanAdPlacementRPC(self.request)) {
        NSString *methodName = [self.request valueForHTTPHeaderField:@"methodname"] ?: @"";
        NSString *fakeJson = @"{\"status\":{\"code\":0},\"data\":{\"ad_open\":0,\"ad_type\":[],\"ad_source\":[],\"ios_slot_id\":\"\",\"put_id\":0}}";
        if ([methodName containsString:@"GetUserInfo"]) {
            fakeJson = @"{\"status\":{\"code\":0},\"data\":{\"module_open\":0,\"show_exchange_silk_entry\":false}}";
        }
        NSData *data = [fakeJson dataUsingEncoding:NSUTF8StringEncoding];
        NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                                                  statusCode:200
                                                                 HTTPVersion:@"HTTP/1.1"
                                                                headerFields:@{@"Content-Type": @"application/json"}];
        [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        [self.client URLProtocol:self didLoadData:data];
        [self.client URLProtocolDidFinishLoading:self];
        return;
    }
    
    NSError *cancelErr = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil];
    [self.client URLProtocol:self didFailWithError:cancelErr];
}

- (void)stopLoading {}

@end

%hook NSURLSession

+ (NSURLSession *)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration delegate:(id<NSURLSessionDelegate>)delegate delegateQueue:(NSOperationQueue *)queue {
    if (configuration) {
        NSMutableArray *protocols = configuration.protocolClasses ? [configuration.protocolClasses mutableCopy] : [NSMutableArray array];
        if (![protocols containsObject:[XCSuperAdBlockProtocol class]]) {
            [protocols insertObject:[XCSuperAdBlockProtocol class] atIndex:0];
            configuration.protocolClasses = protocols;
        }
    }
    return %orig(configuration, delegate, queue);
}

+ (NSURLSession *)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration {
    if (configuration) {
        NSMutableArray *protocols = configuration.protocolClasses ? [configuration.protocolClasses mutableCopy] : [NSMutableArray array];
        if (![protocols containsObject:[XCSuperAdBlockProtocol class]]) {
            [protocols insertObject:[XCSuperAdBlockProtocol class] atIndex:0];
            configuration.protocolClasses = protocols;
        }
    }
    return %orig(configuration);
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData * _Nullable, NSURLResponse * _Nullable, NSError * _Nullable))completionHandler {
    if (isXiaoCanAdPlacementRPC(request)) {
        if (completionHandler) {
            NSData *data = [@"{\"status\":{\"code\":0},\"data\":{\"ad_open\":0,\"ad_type\":[],\"ad_source\":[],\"ios_slot_id\":\"\",\"put_id\":0}}" dataUsingEncoding:NSUTF8StringEncoding];
            NSHTTPURLResponse *resp = [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type": @"application/json"}];
            dispatch_async(dispatch_get_main_queue(), ^{
                completionHandler(data, resp, nil);
            });
        }
        return %orig([NSURLRequest requestWithURL:[NSURL URLWithString:@"http://127.0.0.1:0/rpc_ad_blocked"]], nil);
    }
    if (request && shouldBlockAdURL(request.URL)) {
        if (completionHandler) {
            NSError *err = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                completionHandler(nil, nil, err);
            });
        }
        return %orig([NSURLRequest requestWithURL:[NSURL URLWithString:@"http://127.0.0.1:0/ad_blocked"]], nil);
    }
    return %orig;
}

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)bodyData completionHandler:(void (^)(NSData * _Nullable, NSURLResponse * _Nullable, NSError * _Nullable))completionHandler {
    if (request && shouldBlockAdURL(request.URL)) {
        if (completionHandler) {
            NSError *err = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                completionHandler(nil, nil, err);
            });
        }
        return (NSURLSessionUploadTask *)[self dataTaskWithURL:[NSURL URLWithString:@"http://127.0.0.1:0/upload_blocked"]];
    }
    return %orig;
}

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)bodyData {
    if (request && shouldBlockAdURL(request.URL)) {
        return (NSURLSessionUploadTask *)[self dataTaskWithURL:[NSURL URLWithString:@"http://127.0.0.1:0/upload_blocked"]];
    }
    return %orig;
}

%end


// ============================================================================
// 3. 核心黑科技：Hook 底层 C 函数 dispatch_after + NSTimer + UIView 动画
// Swift 写的 LaunchUtil 和 AdManager 使用 DispatchQueue.main.asyncAfter 控制内置启动页停留时长！
// 我们在启动前 5 秒内，将主队列上所有 >= 0.3 秒的延迟任务直接压缩为 0.01 秒瞬间执行！
// ============================================================================
%hookf(void, dispatch_after, dispatch_time_t when, dispatch_queue_t queue, dispatch_block_t block) {
    // 仅在 App 冷启动的前 5.0 秒内开启“时间加速”，且仅针对主线程 UI 队列
    if (CFAbsoluteTimeGetCurrent() - kAppStartTimestamp < 5.0 && queue == dispatch_get_main_queue()) {
        dispatch_time_t now = dispatch_time(DISPATCH_TIME_NOW, 0);
        // 如果设定的延迟时间大于 0.25 秒（例如内置闪屏等待 2s/3s/5s/8s 超时）
        if (when > now + (int64_t)(0.25 * NSEC_PER_SEC)) {
            // 直接把等待时间缩短为 0.01 秒（10毫秒）！让关闭内置闪屏的闭包瞬间执行！
            when = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.01 * NSEC_PER_SEC));
        }
    }
    %orig(when, queue, block);
}

%hook NSTimer

+ (NSTimer *)scheduledTimerWithTimeInterval:(NSTimeInterval)ti target:(id)aTarget selector:(SEL)aSelector userInfo:(id)userInfo repeats:(BOOL)yesOrNo {
    if (CFAbsoluteTimeGetCurrent() - kAppStartTimestamp < 6.0) {
        NSString *targetClass = aTarget ? NSStringFromClass([aTarget class]) : @"";
        NSString *selName = aSelector ? NSStringFromSelector(aSelector) : @"";
        if ([targetClass containsString:@"Launch"] ||
            [targetClass containsString:@"Ad"] ||
            [targetClass containsString:@"Splash"] ||
            [selName containsString:@"splash"] ||
            [selName containsString:@"timeout"] ||
            [selName containsString:@"close"] ||
            (!yesOrNo && ti >= 0.5 && ti <= 10.0)) {
            ti = 0.01;
        }
    }
    return %orig(ti, aTarget, aSelector, userInfo, yesOrNo);
}

+ (NSTimer *)scheduledTimerWithTimeInterval:(NSTimeInterval)interval repeats:(BOOL)repeats block:(void (^)(NSTimer *timer))block {
    if (CFAbsoluteTimeGetCurrent() - kAppStartTimestamp < 6.0) {
        if (!repeats && interval >= 0.5 && interval <= 10.0) {
            interval = 0.01;
        }
    }
    return %orig(interval, repeats, block);
}

+ (NSTimer *)timerWithTimeInterval:(NSTimeInterval)interval repeats:(BOOL)repeats block:(void (^)(NSTimer *timer))block {
    if (CFAbsoluteTimeGetCurrent() - kAppStartTimestamp < 6.0) {
        if (!repeats && interval >= 0.5 && interval <= 10.0) {
            interval = 0.01;
        }
    }
    return %orig(interval, repeats, block);
}

%end

// 把启动期的开屏渐隐过渡动画时间也直接归零，实现“0帧切换”
%hook UIView

+ (void)animateWithDuration:(NSTimeInterval)duration animations:(void (^)(void))animations completion:(void (^)(BOOL finished))completion {
    if (CFAbsoluteTimeGetCurrent() - kAppStartTimestamp < 5.0) {
        duration = 0.0;
    }
    %orig(duration, animations, completion);
}

+ (void)animateWithDuration:(NSTimeInterval)duration delay:(NSTimeInterval)delay options:(UIViewAnimationOptions)options animations:(void (^)(void))animations completion:(void (^)(BOOL finished))completion {
    if (CFAbsoluteTimeGetCurrent() - kAppStartTimestamp < 5.0) {
        duration = 0.0;
        delay = 0.0;
    }
    %orig(duration, delay, options, animations, completion);
}

%end


// ============================================================================
// 4. 精准剿灭内置闪屏：直接从内存清空 LaunchUtil.$__lazy_storage_$_launchView
// 逆向报告 5.2 节明确指出：内置启动页面就是 LaunchUtil 持有的 $__lazy_storage_$_launchView！
// ============================================================================
static void destroyInternalLaunchViewAndClose(id obj) {
    if (!obj) return;
    
    unsigned int ivarCount = 0;
    Ivar *ivars = class_copyIvarList([obj class], &ivarCount);
    if (ivars) {
        for (unsigned int i = 0; i < ivarCount; i++) {
            const char *name = ivar_getName(ivars[i]);
            if (!name) continue;
            NSString *ivarName = [NSString stringWithUTF8String:name];
            
            // 1. 强行将 ignoreSplashAd / isClose 布尔属性设为 YES
            if ([ivarName containsString:@"ignoreSplashAd"] || [ivarName containsString:@"isClose"]) {
                const char *type = ivar_getTypeEncoding(ivars[i]);
                if (type && (strcmp(type, "B") == 0 || strcmp(type, "c") == 0)) {
                    *((BOOL *)((char *)obj + ivar_getOffset(ivars[i]))) = YES;
                }
            }
            
            // 2. 精准捕获 LaunchUtil.$__lazy_storage_$_launchView 以及 adWindow
            if ([ivarName containsString:@"launchView"] || 
                [ivarName containsString:@"adWindow"] || 
                [ivarName containsString:@"dyCountdownView"]) {
                const char *type = ivar_getTypeEncoding(ivars[i]);
                if (type && type[0] == '@') {
                    id viewObj = object_getIvar(obj, ivars[i]);
                    if (viewObj && [viewObj isKindOfClass:[UIView class]]) {
                        UIView *v = (UIView *)viewObj;
                        dispatch_async(dispatch_get_main_queue(), ^{
                            v.hidden = YES;
                            v.alpha = 0.0;
                            v.userInteractionEnabled = NO;
                            [v removeFromSuperview];
                        });
                    }
                }
            }
        }
        free(ivars);
    }
    
    // 3. 自动触发该对象的无参关闭/移除方法 (如 hideLaunchView / removeLaunchView / close / dismiss)
    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList([obj class], &methodCount);
    if (methods) {
        for (unsigned int i = 0; i < methodCount; i++) {
            SEL sel = method_getName(methods[i]);
            NSString *selName = NSStringFromSelector(sel);
            if (![selName containsString:@":"] &&
                ([selName containsString:@"close"] ||
                 [selName containsString:@"Close"] ||
                 [selName containsString:@"dismiss"] ||
                 [selName containsString:@"Dismiss"] ||
                 [selName containsString:@"hide"] ||
                 [selName containsString:@"Hide"] ||
                 [selName containsString:@"remove"] ||
                 [selName containsString:@"Remove"] ||
                 [selName containsString:@"skip"] ||
                 [selName containsString:@"Skip"])) {
                char returnType[32];
                method_getReturnType(methods[i], returnType, sizeof(returnType));
                if (strcmp(returnType, "v") == 0) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        ((void (*)(id, SEL))objc_msgSend)(obj, sel);
                    });
                }
            }
        }
        free(methods);
    }
}

// 拦截所有独立广告 UIWindow 及主窗口上挂载的 LaunchView
%hook UIWindow

- (void)makeKeyAndVisible {
    NSString *clsName = NSStringFromClass([self class]);
    NSString *rootVC = self.rootViewController ? NSStringFromClass([self.rootViewController class]) : @"";
    if ([clsName containsString:@"Splash"] || [clsName containsString:@"Ad"] ||
        [rootVC containsString:@"Splash"] || [rootVC containsString:@"AdSplash"]) {
        self.hidden = YES;
        self.alpha = 0.0;
        self.userInteractionEnabled = NO;
        return;
    }
    %orig;
}

- (void)addSubview:(UIView *)view {
    if (view) {
        NSString *viewCls = NSStringFromClass([view class]);
        // 如果往 UIWindow 上直接添加内置的 LaunchView 或 Splash 视图，当场拦截不让它显示！
        if ([viewCls containsString:@"LaunchView"] || 
            [viewCls containsString:@"AdSplash"] || 
            [viewCls containsString:@"SplashView"]) {
            view.hidden = YES;
            view.alpha = 0.0;
            view.userInteractionEnabled = NO;
            return;
        }
    }
    %orig(view);
}

%end

%hook UIView

- (void)didMoveToSuperview {
    %orig;
    if (!self.superview) return;
    
    NSString *clsName = NSStringFromClass([self class]);
    if (!clsName) return;
    
    // 精准拦截内置 LaunchView 与各类广告 View
    if ([clsName containsString:@"LaunchView"] ||
        [clsName containsString:@"AdSplash"] ||
        [clsName containsString:@"SplashView"] ||
        [clsName containsString:@"AdDYCountdownView"] ||
        [clsName containsString:@"AdNativeView"] ||
        [clsName containsString:@"OrderAdCell"] ||
        [clsName containsString:@"MineNativeAdCell"] ||
        [clsName containsString:@"HXIconAdView"] ||
        [clsName containsString:@"LynxTobidFeedAdView"]) {
        
        self.hidden = YES;
        self.alpha = 0.0;
        self.userInteractionEnabled = NO;
        
        UIResponder *resp = [self nextResponder];
        while (resp) {
            NSString *rName = NSStringFromClass([resp class]);
            if ([rName containsString:@"Launch"] || [rName containsString:@"Splash"] || [rName containsString:@"Ad"]) {
                destroyInternalLaunchViewAndClose(resp);
            }
            resp = [resp nextResponder];
        }
        
        if (![self isKindOfClass:[UITableViewCell class]] && ![self isKindOfClass:[UICollectionViewCell class]]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self removeFromSuperview];
            });
        }
    }
}

%end

// 监控 Swift / ObjC 的 LaunchUtil 与 AdManager 实例化
%hook NSObject

- (instancetype)init {
    id instance = %orig;
    if (instance) {
        NSString *clsName = NSStringFromClass([instance class]);
        if ([clsName hasSuffix:@"LaunchUtil"] ||
            [clsName hasSuffix:@"AdManager"] ||
            [clsName containsString:@"AdSplash"] ||
            [clsName containsString:@"LaunchView"]) {
            destroyInternalLaunchViewAndClose(instance);
            // 0.02秒后再补刀一次，防止 Swift lazy 属性在 init 之后才初始化
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.02 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                destroyInternalLaunchViewAndClose(instance);
            });
        }
    }
    return instance;
}

%end


// ============================================================================
// 5. 置空 LaunchUtil / AdManager / 27 个开屏类的展示方法 + 禁用摇一摇
// ============================================================================
static void emptyVoidIMP(id self, SEL _cmd) {}
static id emptyNilIMP(id self, SEL _cmd) { return nil; }

static void swizzleAllLaunchAndSplashClasses(void) {
    // 把 xiaocan.LaunchUtil 也加入短路名单！直接废掉它展示内置闪屏的方法！
    NSArray<NSString *> *targetClasses = @[
        @"xiaocan.LaunchUtil", @"LaunchUtil",
        @"XiaoCanAd.AdSplash", @"XiaoCanAd.AdSplashBU", @"XiaoCanAd.AdSplashMS", @"XiaoCanAd.AdSplashWM",
        @"AdSplash", @"AdSplashBU", @"AdSplashMS", @"AdSplashWM",
        @"CSJSplashAd", @"BUNativeExpressSplashView", @"ABUSplashAd", @"GDTSplashAd",
        @"KSSplashAdView", @"BaiduMobAdSplash", @"WindMillSplashAd", @"MSSplashAd",
        @"BeiZiSplash", @"OctAdSplash", @"QMSplashAd", @"UBiXSplashAd",
        @"FancySplashAd", @"DM_SplashAd", @"YTSplashAd", @"AdbidSplashAd",
        @"LMSplashAd", @"AMPSSplashAd", @"AdScopeADNSplashAd"
    ];
    
    for (NSString *name in targetClasses) {
        Class cls = objc_getClass([name UTF8String]);
        if (!cls) cls = NSClassFromString(name);
        if (!cls) continue;
        
        // 同时処理实例方法与类方法 (MetaClass)
        Class classesToPatch[2] = { cls, object_getClass(cls) };
        for (int c = 0; c < 2; c++) {
            Class currentCls = classesToPatch[c];
            if (!currentCls) continue;
            
            unsigned int count = 0;
            Method *methods = class_copyMethodList(currentCls, &count);
            if (!methods) continue;
            
            for (unsigned int i = 0; i < count; i++) {
                NSString *selName = NSStringFromSelector(method_getName(methods[i]));
                if ([selName containsString:@"load"] || [selName containsString:@"Load"] ||
                    [selName containsString:@"show"] || [selName containsString:@"Show"]) {
                    const char *enc = method_getTypeEncoding(methods[i]);
                    if (enc && enc[0] == 'v') {
                        method_setImplementation(methods[i], (IMP)emptyVoidIMP);
                    } else if (enc && enc[0] == '@') {
                        method_setImplementation(methods[i], (IMP)emptyNilIMP);
                    }
                }
            }
            free(methods);
        }
    }
}

%hook CMMotionManager
- (void)startAccelerometerUpdates {}
- (void)startAccelerometerUpdatesToQueue:(NSOperationQueue *)queue withHandler:(CMAccelerometerHandler)handler {}
- (void)startGyroUpdates {}
- (void)startGyroUpdatesToQueue:(NSOperationQueue *)queue withHandler:(CMGyroHandler)handler {}
- (void)startDeviceMotionUpdates {}
- (void)startDeviceMotionUpdatesToQueue:(NSOperationQueue *)queue withHandler:(CMDeviceMotionHandler)handler {}
%end

%ctor {
    @autoreleasepool {
        kAppStartTimestamp = CFAbsoluteTimeGetCurrent();
        [NSURLProtocol registerClass:[XCSuperAdBlockProtocol class]];
        
        // 立即执行一次，并在 0.02s 后再执行一次，确保 Swift 类表加载完毕后第一时间废掉 LaunchUtil 的 show 方法
        swizzleAllLaunchAndSplashClasses();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.02 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            swizzleAllLaunchAndSplashClasses();
        });
    }
}
