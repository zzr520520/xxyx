#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreMotion/CoreMotion.h>
#import <objc/runtime.h>
#import <objc/message.h>

static CFAbsoluteTime kAppStartTimestamp = 0;

// ============================================================================
// 1. 三方广告网络域名拦截
// ============================================================================
static NSString * const kBlockedAdHosts[] = {
    @"leadmoad.com", @"adbiding.com", @"tobidad.cn", @"tobidad.com", @"sigmob.cn",
    @"pangolin-sdk-toutiao", @"pglstatp-toutiao.com", @"ctobsnssdk.com", @"oceanengine.com",
    @"bdurl.net", @"bytescm.com", @"bytegoofy.com", @"volces.com", @"zijieapi.com",
    @"douyin.com", @"douyinstatic.com", @"gdt.qq.com", @"e.qq.com", @"ugdtimg.com",
    @"gdtimg.com", @"mobads.baidu.com", @"als.baidu.com", @"pos.baidu.com", @"beizi.biz",
    @"adn-plus.com.cn", @"ad-scope.com.cn", @"mentamob.com", @"advlion.com", @"vlion.cn",
    @"fibo.cn", @"fancydsp.com", @"fancyapi.com", @"dmrtb.com", @"richmob.cn",
    @"ubixioe.com", @"tanx.com", @"1rtb.net", @"1rtb.com", @"yunxish.com", @"58iclick.com",
    @"iggrowth.cn", @"innotechx.com", @"etoolads.cn", @"zhangyuyidong.cn", @"hubcloud.com.cn",
    @"nwiztech.com", @"kuaishou.com", @"gifshow.com", @"iadsdk.apple.com", @"adservices.apple.com"
};
static const size_t kBlockedAdHostsCount = sizeof(kBlockedAdHosts) / sizeof(kBlockedAdHosts[0]);

static BOOL shouldBlockAdURL(NSURL *url) {
    if (!url || ![url isKindOfClass:[NSURL class]]) return NO;
    NSString *host = [url host];
    if (!host || ![host isKindOfClass:[NSString class]] || host.length == 0) return NO;
    NSString *lowerHost = [host lowercaseString];
    if ([lowerHost containsString:@"xiaocantech.com"] || [lowerHost containsString:@"realtech-inc.com"] ||
        [lowerHost containsString:@"xinyifm.cn"] || [lowerHost containsString:@"hzaiguojiang.com"] ||
        [lowerHost containsString:@"djtaoke.cn"] || [lowerHost containsString:@"fengkongcloud.com"] ||
        [lowerHost containsString:@"qlogo.cn"] || [lowerHost containsString:@"map.qq.com"] ||
        [lowerHost containsString:@"connect.qq.com"]) {
        return NO;
    }
    for (size_t i = 0; i < kBlockedAdHostsCount; i++) {
        if ([lowerHost containsString:kBlockedAdHosts[i]]) return YES;
    }
    return NO;
}

static BOOL isXiaoCanAdPlacementRPC(NSURLRequest *request) {
    if (!request || !request.URL) return NO;
    NSString *absURL = [request.URL.absoluteString lowercaseString];
    if (![absURL containsString:@"gw.xiaocantech.com/rpc"]) return NO;
    NSString *methodName = [request valueForHTTPHeaderField:@"methodname"];
    NSString *serverName = [request valueForHTTPHeaderField:@"servername"];
    if ((methodName && ([methodName containsString:@"MatchPlacement"] || [methodName containsString:@"AdMobileService"])) ||
        (serverName && [serverName isEqualToString:@"SilkwormAd"])) {
        return YES;
    }
    return NO;
}

@interface XCSuperAdBlockProtocol : NSURLProtocol
@end

@implementation XCSuperAdBlockProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if ([NSURLProtocol propertyForKey:@"XCSuperAdHandled" inRequest:request]) return NO;
    if (isXiaoCanAdPlacementRPC(request) || shouldBlockAdURL(request.URL)) return YES;
    return NO;
}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    NSMutableURLRequest *mutableReq = [self.request mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:@"XCSuperAdHandled" inRequest:mutableReq];
    if (isXiaoCanAdPlacementRPC(self.request)) {
        NSString *methodName = [self.request valueForHTTPHeaderField:@"methodname"] ?: @"";
        NSString *fakeJson = @"{\"status\":{\"code\":0},\"data\":{\"ad_open\":0,\"ad_type\":[],\"ad_source\":[],\"ios_slot_id\":\"\",\"put_id\":0}}";
        // 保留：GetUserInfo 接口同样伪造关闭，防止活动入口/资源位重新拉起
        if ([methodName containsString:@"GetUserInfo"]) {
            fakeJson = @"{\"status\":{\"code\":0},\"data\":{\"module_open\":0,\"show_exchange_silk_entry\":false}}";
        }
        NSData *data = [fakeJson dataUsingEncoding:NSUTF8StringEncoding];
        NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type": @"application/json"}];
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
            dispatch_async(dispatch_get_main_queue(), ^{ completionHandler(data, resp, nil); });
        }
        return %orig([NSURLRequest requestWithURL:[NSURL URLWithString:@"http://127.0.0.1:0/rpc_ad_blocked"]], nil);
    }
    if (request && shouldBlockAdURL(request.URL)) {
        if (completionHandler) {
            NSError *err = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil];
            dispatch_async(dispatch_get_main_queue(), ^{ completionHandler(nil, nil, err); });
        }
        return %orig([NSURLRequest requestWithURL:[NSURL URLWithString:@"http://127.0.0.1:0/ad_blocked"]], nil);
    }
    return %orig;
}
// 保留 2.4.0：拦截 sdk.beizi.biz 等三方 SDK 的 uploadTask 日志上传
- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)bodyData completionHandler:(void (^)(NSData * _Nullable, NSURLResponse * _Nullable, NSError * _Nullable))completionHandler {
    if (request && shouldBlockAdURL(request.URL)) {
        if (completionHandler) {
            NSError *err = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil];
            dispatch_async(dispatch_get_main_queue(), ^{ completionHandler(nil, nil, err); });
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
// 2. 【新增功能】精准拦截并销毁所有“App内置的开屏/活动/资源弹窗控制器与视图”
// ============================================================================
static void dismissOrKillViewController(UIViewController *vc) {
    if (!vc) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (vc.presentingViewController) {
            [vc.presentingViewController dismissViewControllerAnimated:NO completion:nil];
        } else if (vc.navigationController) {
            [vc.navigationController popViewControllerAnimated:NO];
        } else if (vc.view) {
            vc.view.hidden = YES;
            vc.view.alpha = 0.0;
            [vc.view removeFromSuperview];
        }
    });
}

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (CFAbsoluteTimeGetCurrent() - kAppStartTimestamp < 10.0) {
        NSString *clsName = NSStringFromClass([self class]);
        if (!clsName) return;

        // 捕获所有内置开屏、弹窗、活动、广告类控制器
        if ([clsName containsString:@"Splash"] ||
            [clsName containsString:@"splash"] ||
            [clsName containsString:@"Resource"] ||
            [clsName containsString:@"Activity"] ||
            [clsName containsString:@"Popup"] ||
            [clsName containsString:@"RedPacket"] ||
            [clsName containsString:@"AdOpen"]) {

            dismissOrKillViewController(self);
        }
    }
}

- (void)viewDidLoad {
    %orig;
    if (CFAbsoluteTimeGetCurrent() - kAppStartTimestamp < 10.0) {
        NSString *clsName = NSStringFromClass([self class]);
        if (clsName && ([clsName containsString:@"Splash"] || [clsName containsString:@"Resource"] || [clsName containsString:@"Popup"] || [clsName containsString:@"RedPacket"])) {
            dismissOrKillViewController(self);
        }
    }
}

%end


// ============================================================================
// 3. 定时器加速器（保留 2.4.0 全部 3 个方法：确保所有开屏延时 0.01 秒完成）
// ============================================================================
%hook NSTimer

+ (NSTimer *)scheduledTimerWithTimeInterval:(NSTimeInterval)ti target:(id)aTarget selector:(SEL)aSelector userInfo:(id)userInfo repeats:(BOOL)yesOrNo {
    if (CFAbsoluteTimeGetCurrent() - kAppStartTimestamp < 6.0) {
        NSString *targetClass = aTarget ? NSStringFromClass([aTarget class]) : @"";
        NSString *selName = aSelector ? NSStringFromSelector(aSelector) : @"";
        if ([targetClass containsString:@"Launch"] || [targetClass containsString:@"Ad"] || [targetClass containsString:@"Splash"] ||
            [selName containsString:@"splash"] || [selName containsString:@"timeout"] || [selName containsString:@"close"] ||
            (!yesOrNo && ti >= 1.0 && ti <= 10.0)) {
            ti = 0.01;
        }
    }
    return %orig(ti, aTarget, aSelector, userInfo, yesOrNo);
}

+ (NSTimer *)scheduledTimerWithTimeInterval:(NSTimeInterval)interval repeats:(BOOL)repeats block:(void (^)(NSTimer *timer))block {
    if (CFAbsoluteTimeGetCurrent() - kAppStartTimestamp < 6.0) {
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
// 4. 精准触发开屏关闭回调 + 拦截独立 adWindow（保留 2.4.0）
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

// 只针对性隐藏真正的广告视图与 LaunchView（合并 2.4.0 全量类名 + 本次新增类名）
%hook UIView

- (void)didMoveToSuperview {
    %orig;
    if (!self.superview) return;

    NSString *clsName = NSStringFromClass([self class]);
    if (!clsName) return;

    // 1. 如果是 LaunchView / AdSplash / 活动弹窗视图，直接隐藏它并触发其控制器的关闭逻辑
    if ([clsName containsString:@"LaunchView"] ||
        [clsName containsString:@"AdSplash"] ||
        [clsName containsString:@"SplashView"] ||
        [clsName containsString:@"AdDYCountdownView"] ||
        [clsName containsString:@"AdNativeView"] ||
        [clsName containsString:@"OrderAdCell"] ||
        [clsName containsString:@"MineNativeAdCell"] ||
        [clsName containsString:@"HXIconAdView"] ||
        [clsName containsString:@"LynxTobidFeedAdView"] ||
        // 本次新增：资源位 / 活动弹窗 / 红包弹窗
        [clsName containsString:@"ResourceView"] ||
        [clsName containsString:@"PopupView"] ||
        [clsName containsString:@"RedPacketView"]) {

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

// 监控 AdManager / LaunchUtil / AdSplash 初始化，第一时间设置 ignoreSplashAd = YES（保留 2.4.0）
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
// 5. 置空 27 个开屏广告类的 load / show 方法（保留 2.4.0）+ 禁用摇一摇传感器
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

        // 保留 2.4.0：延迟 0.03 秒置空所有开屏 SDK 的 load/show 方法
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            disableAllSplashSDKMethods();
        });
    }
}
