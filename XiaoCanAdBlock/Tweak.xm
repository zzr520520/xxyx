#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreMotion/CoreMotion.h>
#import <objc/runtime.h>
#import <objc/message.h>

// 记录 App 启动时间戳，用于启动期高频撕除开屏遮罩
static CFAbsoluteTime kAppLaunchTime = 0;

// ============================================================================
// 1. 全量广告与追踪域名黑名单 (纯 C 静态常量数组，防内存释放崩溃)
// ============================================================================
static NSString * const kBlockedAdHosts[] = {
    @"leadmoad.com",            // adsbid.leadmoad.com, ads-bid.leadmoad.com
    @"adbiding.com",            // sdkconf.adbiding.com, sl.adbiding.com
    @"tobidad.cn",              // c.tobidad.cn
    @"tobidad.com",
    @"sigmob.cn",               // tm.sigmob.cn, dc.sigmob.cn, adservice.sigmob.cn
    @"pangolin-sdk-toutiao",    // api-access.pangolin-sdk-toutiao.com / toutiao1.com / log-api
    @"pglstatp-toutiao.com",    // sf3-fe-tos / sf6-fe-tos.pglstatp-toutiao.com
    @"ctobsnssdk.com",          // toblog.ctobsnssdk.com
    @"oceanengine.com",         // analytics.oceanengine.com
    @"bdurl.net",               // dig.bdurl.net
    @"bytescm.com",             // lf-cdn-tos.bytescm.com
    @"bytegoofy.com",
    @"volces.com",              // apmplus.volces.com
    @"zijieapi.com",            // tnc3-alisc1.zijieapi.com
    @"douyin.com",              // webcast-open.douyin.com (pangle setting)
    @"douyinstatic.com",
    @"gdt.qq.com",              // mi.gdt.qq.com, c2.gdt.qq.com, win.gdt.qq.com, v2.gdt.qq.com
    @"e.qq.com",                // sdk.e.qq.com
    @"ugdtimg.com",             // pgdt.ugdtimg.com, adsmind.ugdtimg.com
    @"gdtimg.com",
    @"mobads.baidu.com",
    @"baidu.com",               // als.baidu.com, pos.baidu.com
    @"beizi.biz",               // sdk.beizi.biz
    @"adn-plus.com.cn",
    @"ad-scope.com.cn",
    @"mentamob.com",            // api-v3.mentamob.com, api-nxs-v3/v4.mentamob.com
    @"advlion.com",             // bj-td-menta-01-callback.advlion.com, td-nexus.advlion.com
    @"vlion.cn",
    @"fibo.cn",                 // kbsvr.fibo.cn
    @"fancydsp.com",            // mpcfg.fancydsp.com
    @"fancyapi.com",            // t2.fancyapi.com
    @"dmrtb.com",               // dmsdk-api.dmrtb.com
    @"richmob.cn",              // adsdk.richmob.cn
    @"ubixioe.com",
    @"tanx.com",
    @"1rtb.net",                // sdk.1rtb.net (美数 MSAdSDK)
    @"1rtb.com",
    @"yunxish.com",
    @"58iclick.com",
    @"iggrowth.cn",
    @"innotechx.com",
    @"etoolads.cn",
    @"zhangyuyidong.cn",        // sdk.zhangyuyidong.cn
    @"hubcloud.com.cn",         // sdktmp.hubcloud.com.cn
    @"nwiztech.com",            // yyz-api.nwiztech.com
    @"kuaishou.com",
    @"gifshow.com"
};

static const size_t kBlockedAdHostsCount = sizeof(kBlockedAdHosts) / sizeof(kBlockedAdHosts[0]);

static BOOL shouldBlockURL(NSURL *url) {
    if (!url || ![url isKindOfClass:[NSURL class]]) return NO;
    NSString *host = [url host];
    if (!host || ![host isKindOfClass:[NSString class]] || host.length == 0) return NO;

    NSString *lowerHost = [host lowercaseString];

    // 核心业务域名绝对放行
    if ([lowerHost containsString:@"xiaocantech.com"] ||
        [lowerHost containsString:@"realtech-inc.com"] ||
        [lowerHost containsString:@"xinyifm.cn"] ||
        [lowerHost containsString:@"hzaiguojiang.com"] ||
        [lowerHost containsString:@"djtaoke.cn"] ||
        [lowerHost containsString:@"fengkongcloud.com"] ||
        [lowerHost containsString:@"qlogo.cn"]) {
        return NO;
    }

    for (size_t i = 0; i < kBlockedAdHostsCount; i++) {
        if ([lowerHost containsString:kBlockedAdHosts[i]]) {
            return YES;
        }
    }
    return NO;
}

// 列出应用全部窗口（UIApplication.windows 在 iOS 15 起被标记废弃，这里局部屏蔽告警）
static NSArray<UIWindow *> *xc_allWindows(void) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [[UIApplication sharedApplication] windows];
#pragma clang diagnostic pop
}

// ============================================================================
// 2. 直接 Hook NSURLSession 任务创建 (解决 NSURLProtocol 被私有 Session 绕过的问题)
// ============================================================================
%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData * _Nullable, NSURLResponse * _Nullable, NSError * _Nullable))completionHandler {
    if (request && request.URL) {
        // 1. 拦截小蚕自有网关的广告配置请求 (AdMobileService.MatchPlacement)
        NSString *absURL = [request.URL.absoluteString lowercaseString];
        if ([absURL containsString:@"gw.xiaocantech.com/rpc"]) {
            NSString *methodHeader = [request valueForHTTPHeaderField:@"methodname"];
            NSString *bodyStr = request.HTTPBody ? [[NSString alloc] initWithData:request.HTTPBody encoding:NSUTF8StringEncoding] : @"";
            if ((methodHeader && [methodHeader containsString:@"AdMobileService"]) ||
                (bodyStr && [bodyStr containsString:@"MatchPlacement"])) {
                if (completionHandler) {
                    NSData *emptyAdData = [@"{\"status\":{\"code\":0},\"data\":{\"ad_open\":0,\"ad_type\":[],\"ad_source\":[]}}" dataUsingEncoding:NSUTF8StringEncoding];
                    NSHTTPURLResponse *resp = [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type": @"application/json"}];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        completionHandler(emptyAdData, resp, nil);
                    });
                }
                return %orig([NSURLRequest requestWithURL:[NSURL URLWithString:@"http://127.0.0.1:0/rpc_ad_blocked"]], nil);
            }
        }

        // 2. 拦截所有三方广告 SDK 请求，当场秒回 Cancelled 错误，0 毫秒等待！
        if (shouldBlockURL(request.URL)) {
            if (completionHandler) {
                NSError *cancelErr = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil];
                dispatch_async(dispatch_get_main_queue(), ^{
                    completionHandler(nil, nil, cancelErr);
                });
            }
            return %orig([NSURLRequest requestWithURL:[NSURL URLWithString:@"http://127.0.0.1:0/ad_blocked"]], nil);
        }
    }
    return %orig;
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    if (request && shouldBlockURL(request.URL)) {
        return %orig([NSURLRequest requestWithURL:[NSURL URLWithString:@"http://127.0.0.1:0/ad_blocked"]]);
    }
    return %orig;
}

- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url completionHandler:(void (^)(NSData * _Nullable, NSURLResponse * _Nullable, NSError * _Nullable))completionHandler {
    if (shouldBlockURL(url)) {
        if (completionHandler) {
            NSError *cancelErr = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                completionHandler(nil, nil, cancelErr);
            });
        }
        return %orig([NSURL URLWithString:@"http://127.0.0.1:0/ad_blocked"], nil);
    }
    return %orig;
}

- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url {
    if (shouldBlockURL(url)) {
        return %orig([NSURL URLWithString:@"http://127.0.0.1:0/ad_blocked"]);
    }
    return %orig;
}

%end


// ============================================================================
// 3. 核心破局：强行撕掉 LaunchUtil.launchView 遮罩与独立 adWindow！
// 为什么“大额红包”页面还在？因为它要么是盖在 FlutterViewController 顶上的 launchView，
// 要么是 AdSplashWM / AdSplashMS 创建的第二层 UIWindow！
// ============================================================================

// 判断一个 View 或 VC 树里是否包含小蚕的 Flutter 主界面
static BOOL containsMainFlutterOrTab(UIView *view) {
    if (!view) return NO;
    UIResponder *resp = [view nextResponder];
    while (resp) {
        NSString *respClass = NSStringFromClass([resp class]);
        if ([respClass containsString:@"Flutter"] ||
            [respClass containsString:@"TabBar"] ||
            [respClass containsString:@"Navigation"] ||
            [respClass containsString:@"Home"]) {
            return YES;
        }
        resp = [resp nextResponder];
    }
    for (UIView *sub in view.subviews) {
        NSString *subClass = NSStringFromClass([sub class]);
        if ([subClass containsString:@"Flutter"] || [subClass containsString:@"TabBar"]) {
            return YES;
        }
        if (containsMainFlutterOrTab(sub)) return YES;
    }
    return NO;
}

// 递归检查一个视图树是否是全屏启动图/广告遮罩（包含全屏 UIImageView 或倒计时按钮，且不包含 Flutter 主界面）
static BOOL isSplashOrLaunchOverlayView(UIView *view) {
    if (!view || view.hidden || view.alpha < 0.01) return NO;

    NSString *clsName = NSStringFromClass([view class]);
    // 绝对保护 Flutter 视图和系统核心容器
    if ([clsName containsString:@"Flutter"] ||
        [clsName isEqualToString:@"UILayoutContainerView"] ||
        [clsName isEqualToString:@"UINavigationTransitionView"] ||
        [clsName isEqualToString:@"UIViewControllerWrapperView"] ||
        [clsName isEqualToString:@"UITransitionView"] ||
        [clsName isEqualToString:@"UIDropShadowView"]) {
        return NO;
    }

    // 如果类名直接暴露了 Launch / Splash / Ad
    if ([clsName containsString:@"Launch"] ||
        [clsName containsString:@"Splash"] ||
        [clsName containsString:@"splash"] ||
        [clsName containsString:@"AdDYCountdown"] ||
        [clsName containsString:@"Tobid"] ||
        [clsName containsString:@"WindMill"] ||
        [clsName containsString:@"CSJ"] ||
        [clsName containsString:@"BUAd"] ||
        [clsName containsString:@"GDT"] ||
        [clsName containsString:@"MSAd"]) {
        return YES;
    }

    // 如果这个视图是直接挂在 UIWindow 或根视图上的全屏 View，且它内部没有 Flutter 引擎，只有图片/Label
    CGSize screenSize = [UIScreen mainScreen].bounds.size;
    if (view.bounds.size.width >= screenSize.width * 0.85 &&
        view.bounds.size.height >= screenSize.height * 0.70) {
        if (!containsMainFlutterOrTab(view)) {
            // 检查它自身或子视图里有没有大尺寸的 UIImageView（即“大额红包在小蚕”那张背景图）
            if ([view isKindOfClass:[UIImageView class]]) {
                return YES;
            }
            for (UIView *sub in view.subviews) {
                if ([sub isKindOfClass:[UIImageView class]] &&
                    sub.bounds.size.height >= screenSize.height * 0.5) {
                    return YES;
                }
            }
        }
    }
    return NO;
}

// 扫描当前所有 UIWindow，强杀独立广告 adWindow 以及盖在主窗口上的 launchView
static void purgeAllSplashWindowsAndViews(void) {
    NSArray<UIWindow *> *windows = xc_allWindows();
    UIWindow *mainFlutterWindow = nil;

    // 先找到承载 Flutter 主界面的真正主窗口
    for (UIWindow *win in windows) {
        if (containsMainFlutterOrTab(win)) {
            mainFlutterWindow = win;
            break;
        }
    }

    for (UIWindow *win in windows) {
        NSString *winClass = NSStringFromClass([win class]);
        if ([winClass containsString:@"UITextEffectsWindow"] ||
            [winClass containsString:@"UIRemoteKeyboardWindow"] ||
            [winClass containsString:@"UIStatusBarWindow"]) {
            continue;
        }

        // 1. 如果已经找到了主窗口，任何其他全屏独立 UIWindow（如 AdSplashWM.adWindow / AdSplashMS.adWindow）全部强行隐藏销毁！
        if (mainFlutterWindow && win != mainFlutterWindow) {
            win.hidden = YES;
            win.alpha = 0.0;
            win.userInteractionEnabled = NO;
            win.windowLevel = -1000;
            win.rootViewController = nil;
            continue;
        }

        // 2. 遍历窗口内部的所有直接子视图和根控制器子视图，撕掉 LaunchUtil.launchView 遮罩！
        for (UIView *sub in [win.subviews copy]) {
            if (isSplashOrLaunchOverlayView(sub)) {
                sub.hidden = YES;
                sub.alpha = 0.0;
                sub.userInteractionEnabled = NO;
                [sub removeFromSuperview];
            }
        }

        if (win.rootViewController && win.rootViewController.isViewLoaded) {
            UIView *rootView = win.rootViewController.view;
            for (UIView *sub in [rootView.subviews copy]) {
                if (isSplashOrLaunchOverlayView(sub)) {
                    sub.hidden = YES;
                    sub.alpha = 0.0;
                    sub.userInteractionEnabled = NO;
                    [sub removeFromSuperview];
                }
            }
        }
    }

    // 3. 直接通过 Swift 运行时查找 xiaocan.LaunchUtil 和 xiaocan.AdManager 单例或 Ivar，强行置空 launchView
    Class launchUtilCls = objc_getClass("xiaocan.LaunchUtil");
    if (!launchUtilCls) launchUtilCls = objc_getClass("LaunchUtil");
    if (launchUtilCls) {
        // 如果有类方法或共享实例，尝试清理
    }
}

// ============================================================================
// 4. Hook Swift / ObjC 的 AdManager 与 LaunchUtil 内部实例变量
// ============================================================================
__attribute__((unused))
static void forceClearObjectSplashIvars(id obj) {
    if (!obj) return;
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList([obj class], &count);
    if (!ivars) return;

    for (unsigned int i = 0; i < count; i++) {
        const char *name = ivar_getName(ivars[i]);
        if (!name) continue;
        NSString *ivarName = [NSString stringWithUTF8String:name];

        // 命中 LaunchUtil.$__lazy_storage_$_launchView 或 AdSplash*.adWindow / splashAd
        if ([ivarName containsString:@"launchView"] ||
            [ivarName containsString:@"adWindow"] ||
            [ivarName containsString:@"splashAd"] ||
            [ivarName containsString:@"splashTobidAd"] ||
            [ivarName containsString:@"splashBUAd"] ||
            [ivarName containsString:@"dyCountdownView"]) {

            const char *type = ivar_getTypeEncoding(ivars[i]);
            if (type && type[0] == '@') {
                id val = object_getIvar(obj, ivars[i]);
                if (val && [val isKindOfClass:[UIView class]]) {
                    UIView *v = (UIView *)val;
                    v.hidden = YES;
                    v.alpha = 0.0;
                    v.userInteractionEnabled = NO;
                    [v removeFromSuperview];
                }
            }
        }
    }
    free(ivars);
}

%hook UIView

- (void)didMoveToSuperview {
    %orig;
    if (!self.superview) return;

    // 启动前 15 秒内，任何挂载到视图树上的可疑全屏启动图/广告遮罩，当场销毁！
    if (CFAbsoluteTimeGetCurrent() - kAppLaunchTime < 15.0) {
        if (isSplashOrLaunchOverlayView(self)) {
            self.hidden = YES;
            self.alpha = 0.0;
            self.userInteractionEnabled = NO;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self removeFromSuperview];
            });
            return;
        }
    }

    // 平时浏览时的信息流广告视图拦截
    NSString *clsName = NSStringFromClass([self class]);
    if ([clsName containsString:@"AdSplash"] ||
        [clsName containsString:@"AdNativeView"] ||
        [clsName containsString:@"OrderAdCell"] ||
        [clsName containsString:@"MineNativeAdCell"] ||
        [clsName containsString:@"HXIconAdView"] ||
        [clsName containsString:@"LynxTobidFeedAdView"] ||
        [clsName containsString:@"AdDYCountdownView"]) {
        self.hidden = YES;
        self.alpha = 0.0;
        self.userInteractionEnabled = NO;
        self.frame = CGRectZero;
        if (![self isKindOfClass:[UITableViewCell class]] && ![self isKindOfClass:[UICollectionViewCell class]]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self removeFromSuperview];
            });
        }
    }
}

- (void)didMoveToWindow {
    %orig;
    if (!self.window) return;
    if (CFAbsoluteTimeGetCurrent() - kAppLaunchTime < 15.0) {
        if (isSplashOrLaunchOverlayView(self)) {
            self.hidden = YES;
            self.alpha = 0.0;
            self.userInteractionEnabled = NO;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self removeFromSuperview];
            });
        }
    }
}

%end

// ============================================================================
// 5. 彻底禁用 20+ 家三方广告 SDK 的初始化与开屏加载方法 (复刻报告 3.2 节 SDK 方法置空)
// ============================================================================
static void nopMethodIMP(id self, SEL _cmd) {
    // 什么都不做，直接短路返回
}

static id nilMethodIMP(id self, SEL _cmd) {
    return nil;
}

static void swizzleAdSDKClasses(void) {
    NSArray<NSString *> *adSplashClassNames = @[
        @"XiaoCanAd.AdSplash",
        @"XiaoCanAd.AdSplashBU",
        @"XiaoCanAd.AdSplashMS",
        @"XiaoCanAd.AdSplashWM",
        @"AdSplash",
        @"AdSplashBU",
        @"AdSplashMS",
        @"AdSplashWM",
        @"CSJSplashAd",
        @"BUNativeExpressSplashView",
        @"ABUSplashAd",
        @"GDTSplashAd",
        @"KSSplashAdView",
        @"BaiduMobAdSplash",
        @"WindMillSplashAd",
        @"MSSplashAd",
        @"BeiZiSplash",
        @"OctAdSplash",
        @"QMSplashAd",
        @"UBiXSplashAd",
        @"FancySplashAd",
        @"DM_SplashAd",
        @"YTSplashAd",
        @"AdbidSplashAd",
        @"LMSplashAd",
        @"AMPSSplashAd",
        @"AdScopeADNSplashAd"
    ];

    for (NSString *clsName in adSplashClassNames) {
        Class cls = NSClassFromString(clsName);
        if (!cls) continue;

        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        if (!methods) continue;

        for (unsigned int i = 0; i < methodCount; i++) {
            SEL sel = method_getName(methods[i]);
            NSString *selName = NSStringFromSelector(sel);
            // 凡是 load / show / display 相关方法，全部置空短路！
            if ([selName containsString:@"load"] ||
                [selName containsString:@"Load"] ||
                [selName containsString:@"show"] ||
                [selName containsString:@"Show"]) {
                const char *typeEncoding = method_getTypeEncoding(methods[i]);
                if (typeEncoding && typeEncoding[0] == 'v') {
                    method_setImplementation(methods[i], (IMP)nopMethodIMP);
                } else if (typeEncoding && typeEncoding[0] == '@') {
                    method_setImplementation(methods[i], (IMP)nilMethodIMP);
                }
            }
        }
        free(methods);
    }
}

// ============================================================================
// 6. 禁用摇一摇与扭一扭传感器
// ============================================================================
%hook CMMotionManager
- (void)startAccelerometerUpdates {}
- (void)startAccelerometerUpdatesToQueue:(NSOperationQueue *)queue withHandler:(CMAccelerometerHandler)handler {}
- (void)startGyroUpdates {}
- (void)startGyroUpdatesToQueue:(NSOperationQueue *)queue withHandler:(CMGyroHandler)handler {}
- (void)startDeviceMotionUpdates {}
- (void)startDeviceMotionUpdatesToQueue:(NSOperationQueue *)queue withHandler:(CMDeviceMotionHandler)handler {}
%end

// ============================================================================
// 7. 入口函数：启动 50ms 高频清理雷达 + 动态库加载监听
// ============================================================================
%ctor {
    @autoreleasepool {
        kAppLaunchTime = CFAbsoluteTimeGetCurrent();

        // 延迟 0.05 秒待所有 Framework 加载完毕后，置空所有广告 SDK 的开屏类方法
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            swizzleAdSDKClasses();
        });

        // 启动前 10 秒内，每 0.05 秒（50毫秒）执行一次全窗口扫描，一旦发现“大额红包”遮罩或独立 adWindow，0.05 秒内立即撕掉！
        for (int i = 1; i <= 200; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                purgeAllSplashWindowsAndViews();
            });
        }
    }
}
