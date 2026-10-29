#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreMotion/CoreMotion.h>
#import <objc/runtime.h>
#import <objc/message.h>

static CFAbsoluteTime kAppStartTimestamp = 0;

// ============================================================================
// 1. 全量广告域名黑名单 (包含最新抓包中的 sdk.beizi.biz 等全部三方域名)
// ============================================================================
static NSString * const kBlockedAdHosts[] = {
    @"leadmoad.com",
    @"adbiding.com",
    @"tobidad.cn",
    @"tobidad.com",
    @"sigmob.cn",
    @"pangolin-sdk-toutiao",
    @"pglstatp-toutiao.com",
    @"ctobsnssdk.com",
    @"oceanengine.com",
    @"bdurl.net",
    @"bytescm.com",
    @"bytegoofy.com",
    @"volces.com",
    @"zijieapi.com",
    @"douyin.com",
    @"douyinstatic.com",
    @"gdt.qq.com",
    @"e.qq.com",
    @"ugdtimg.com",
    @"gdtimg.com",
    @"mobads.baidu.com",
    @"als.baidu.com",
    @"pos.baidu.com",
    @"beizi.biz",               // 抓包第11条: sdk.beizi.biz/v1/api/sdk/log/p/f
    @"adn-plus.com.cn",
    @"ad-scope.com.cn",
    @"mentamob.com",
    @"advlion.com",
    @"vlion.cn",
    @"fibo.cn",
    @"fancydsp.com",
    @"fancyapi.com",
    @"dmrtb.com",
    @"richmob.cn",
    @"ubixioe.com",
    @"tanx.com",
    @"1rtb.net",
    @"1rtb.com",
    @"yunxish.com",
    @"58iclick.com",
    @"iggrowth.cn",
    @"innotechx.com",
    @"etoolads.cn",
    @"zhangyuyidong.cn",
    @"hubcloud.com.cn",
    @"nwiztech.com",
    @"kuaishou.com",
    @"gifshow.com",
    @"iadsdk.apple.com",        // 抓包第22条: ca.iadsdk.apple.com
    @"adservices.apple.com"     // 抓包第20条: api-adservices.apple.com
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

// 检查是否为小蚕网关的开屏广告下发接口 (AdMobileService.MatchPlacement)
static BOOL isXiaoCanAdPlacementRPC(NSURLRequest *request) {
    if (!request || !request.URL) return NO;
    NSString *absURL = [request.URL.absoluteString lowercaseString];
    if (![absURL containsString:@"gw.xiaocantech.com/rpc"]) return NO;
    
    NSString *methodName = [request valueForHTTPHeaderField:@"methodname"];
    NSString *serverName = [request valueForHTTPHeaderField:@"servername"];
    
    // 精准命中抓包第 9 条：methodname: AdMobileService.MatchPlacement / servername: SilkwormAd
    if (methodName && ([methodName containsString:@"MatchPlacement"] || [methodName containsString:@"AdMobileService"])) {
        return YES;
    }
    if (serverName && [serverName isEqualToString:@"SilkwormAd"]) {
        return YES;
    }
    return NO;
}


// ============================================================================
// 2. 协议层秒回伪造数据 (同时兼容 Alamofire Delegate 模式与闭包模式)
// 解决上一版 AdMobileService.MatchPlacement 漏网返回 ad_open: 1 的问题！
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
    
    // 如果是小蚕自己的 AdMobileService.MatchPlacement，立即返回 ad_open = 0（关闭开屏！）
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
    
    // 第三方广告 SDK 请求（包含 sdk.beizi.biz 上传等），直接秒抛 Cancelled 错误
    NSError *cancelErr = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil];
    [self.client URLProtocol:self didFailWithError:cancelErr];
}

- (void)stopLoading {
}

@end


// ============================================================================
// 3. 拦截 NSURLSession 创建与所有 Task (确保 Alamofire 100% 走 XCSuperAdBlockProtocol)
// ============================================================================
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

// 双保险：直接在 Task 入口处拦截
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

// 拦截抓包第 11 条 sdk.beizi.biz 的 uploadTask 请求
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
// 4. 破除“白屏干等几秒”的杀手锏：快进开屏超时定时器 + 缩短 GCD 延迟！
// 为什么之前会白屏等一会儿才进去？因为 App 启动时设置了 3~8 秒的开屏等待 Timer！
// 我们直接把启动前 6 秒内所有 >0.3 秒的单次等待 Timer 缩短为 0.01 秒立即触发！
// ============================================================================
%hook NSTimer

+ (NSTimer *)scheduledTimerWithTimeInterval:(NSTimeInterval)ti target:(id)aTarget selector:(SEL)aSelector userInfo:(id)userInfo repeats:(BOOL)yesOrNo {
    // 在 App 冷启动的前 6 秒内：
    if (CFAbsoluteTimeGetCurrent() - kAppStartTimestamp < 6.0) {
        NSString *targetClass = aTarget ? NSStringFromClass([aTarget class]) : @"";
        NSString *selName = aSelector ? NSStringFromSelector(aSelector) : @"";
        
        // 如果定时器的 Target 是 LaunchUtil / AdManager / Splash，或者它是一个 1.0~10.0 秒的不重复超时定时器
        if ([targetClass containsString:@"Launch"] ||
            [targetClass containsString:@"Ad"] ||
            [targetClass containsString:@"Splash"] ||
            [selName containsString:@"splash"] ||
            [selName containsString:@"timeout"] ||
            [selName containsString:@"close"] ||
            (!yesOrNo && ti >= 1.0 && ti <= 10.0)) {
            ti = 0.01; // 8秒等待瞬间变成 0.01 秒！直接触发关闭进入首页！
        }
    }
    return %orig(ti, aTarget, aSelector, userInfo, yesOrNo);
}

+ (NSTimer *)scheduledTimerWithTimeInterval:(NSTimeInterval)interval repeats:(BOOL)repeats block:(void (^)(NSTimer *timer))block {
    if (CFAbsoluteTimeGetCurrent() - kAppStartTimestamp < 6.0) {
        // Swift 常用 block 版 Timer 做开屏 3~8 秒超时兜底
        if (!repeats && interval >= 1.0 && interval <= 10.0) {
            interval = 0.01;
        }
    }
    return %orig(interval, repeats, block);
}

+ (NSTimer *)timerWithTimeInterval:(NSTimeInterval)interval repeats:(BOOL)repeats block:(void (^)(NSTimer *timer))block {
    if (CFAbsoluteTimeGetCurrent() - kAppStartTimestamp < 6.0) {
        if (!repeats && interval >= 1.0 && interval <= 10.0) {
            interval = 0.01;
        }
    }
    return %orig(interval, repeats, block);
}

%end


// ============================================================================
// 5. 精准触发开屏关闭回调 + 拦截独立 adWindow（不再粗暴拆子视图，彻底杜绝白屏！）
// ============================================================================

// 尝试调用开屏对象的关闭方法或执行其关闭闭包
static void triggerSplashCloseIfPossible(id obj) {
    if (!obj) return;
    
    // 1. 先把 ignoreSplashAd 和 isClose 设为 YES
    unsigned int ivarCount = 0;
    Ivar *ivars = class_copyIvarList([obj class], &ivarCount);
    if (ivars) {
        for (unsigned int i = 0; i < ivarCount; i++) {
            const char *name = ivar_getName(ivars[i]);
            if (!name) continue;
            NSString *ivarName = [NSString stringWithUTF8String:name];
            if ([ivarName containsString:@"ignoreSplashAd"] || [ivarName containsString:@"isClose"]) {
                const char *type = ivar_getTypeEncoding(ivars[i]);
                if (type && (strcmp(type, "B") == 0 || strcmp(type, "c") == 0)) {
                    *((BOOL *)((char *)obj + ivar_getOffset(ivars[i]))) = YES;
                }
            }
        }
        free(ivars);
    }
    
    // 2. 查找无参数的 close / dismiss / skip / finish 方法并调用
    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList([obj class], &methodCount);
    if (methods) {
        for (unsigned int i = 0; i < methodCount; i++) {
            SEL sel = method_getName(methods[i]);
            NSString *selName = NSStringFromSelector(sel);
            // 匹配无参数（没有冒号）的关闭方法
            if (![selName containsString:@":"] &&
                ([selName containsString:@"close"] ||
                 [selName containsString:@"Close"] ||
                 [selName containsString:@"dismiss"] ||
                 [selName containsString:@"Dismiss"] ||
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

// 拦截独立广告 UIWindow (AdSplashMS / AdSplashWM 的 adWindow)
%hook UIWindow

- (void)makeKeyAndVisible {
    NSString *clsName = NSStringFromClass([self class]);
    NSString *rootVC = self.rootViewController ? NSStringFromClass([self.rootViewController class]) : @"";
    
    // 如果这个 Window 是专门为 Splash/Ad 创建的独立窗口，直接拒绝显示！
    if ([clsName containsString:@"Splash"] || [clsName containsString:@"Ad"] ||
        [rootVC containsString:@"Splash"] || [rootVC containsString:@"AdSplash"]) {
        self.hidden = YES;
        self.alpha = 0.0;
        self.userInteractionEnabled = NO;
        return;
    }
    %orig;
}

- (void)setHidden:(BOOL)hidden {
    if (!hidden) {
        NSString *clsName = NSStringFromClass([self class]);
        NSString *rootVC = self.rootViewController ? NSStringFromClass([self.rootViewController class]) : @"";
        if ([clsName containsString:@"Splash"] || [rootVC containsString:@"Splash"] || [rootVC containsString:@"AdSplash"]) {
            %orig(YES);
            return;
        }
    }
    %orig;
}

%end

// 只针对性隐藏真正的广告视图与 LaunchView，绝不误拆普通 UIView 容器底板（防白屏！）
%hook UIView

- (void)didMoveToSuperview {
    %orig;
    if (!self.superview) return;
    
    NSString *clsName = NSStringFromClass([self class]);
    if (!clsName) return;
    
    // 1. 如果是 LaunchView 或 AdSplash 视图，直接隐藏它并触发其控制器的关闭逻辑
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
                triggerSplashCloseIfPossible(resp);
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

// 监控 AdManager / LaunchUtil / AdSplash 初始化，第一时间设置 ignoreSplashAd = YES
%hook NSObject

- (instancetype)init {
    id instance = %orig;
    if (instance) {
        NSString *clsName = NSStringFromClass([instance class]);
        if ([clsName hasSuffix:@"AdManager"] ||
            [clsName hasSuffix:@"LaunchUtil"] ||
            [clsName containsString:@"AdSplash"] ||
            [clsName containsString:@"AdForceCloseManager"]) {
            triggerSplashCloseIfPossible(instance);
        }
    }
    return instance;
}

%end


// ============================================================================
// 6. 置空 27 个开屏广告类的 load / show 方法 + 禁用摇一摇传感器
// ============================================================================
static void emptyVoidIMP(id self, SEL _cmd) {}
static id emptyNilIMP(id self, SEL _cmd) { return nil; }

static void disableAllSplashSDKMethods(void) {
    NSArray<NSString *> *splashClasses = @[
        @"XiaoCanAd.AdSplash", @"XiaoCanAd.AdSplashBU", @"XiaoCanAd.AdSplashMS", @"XiaoCanAd.AdSplashWM",
        @"AdSplash", @"AdSplashBU", @"AdSplashMS", @"AdSplashWM",
        @"CSJSplashAd", @"BUNativeExpressSplashView", @"ABUSplashAd", @"GDTSplashAd",
        @"KSSplashAdView", @"BaiduMobAdSplash", @"WindMillSplashAd", @"MSSplashAd",
        @"BeiZiSplash", @"OctAdSplash", @"QMSplashAd", @"UBiXSplashAd",
        @"FancySplashAd", @"DM_SplashAd", @"YTSplashAd", @"AdbidSplashAd",
        @"LMSplashAd", @"AMPSSplashAd", @"AdScopeADNSplashAd"
    ];
    
    for (NSString *name in splashClasses) {
        Class cls = NSClassFromString(name);
        if (!cls) continue;
        unsigned int count = 0;
        Method *methods = class_copyMethodList(cls, &count);
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
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            disableAllSplashSDKMethods();
        });
    }
}
