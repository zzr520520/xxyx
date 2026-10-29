#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// =========================================================================
// 模块一：NSURLProtocol 底层秒回（复刻报告 3.2 节 XCAdBlock 核心机制）
// 1. 拦截业务网关 MatchPlacement，直接把 ad_open: 1 改为 0
// 2. 拦截 43 个广告域名，0.001秒返回空成功包，绝不触发 8 秒超时重试
// =========================================================================

@interface XCFastPassProtocol : NSURLProtocol
@end

@implementation XCFastPassProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    NSString *url = request.URL.absoluteString;
    if (!url) return NO;

    // 1. 拦截小蚕业务网关的开屏广告开关接口 (gw.xiaocantech.com/rpc -> AdMobileService.MatchPlacement)
    NSString *methodName = [request valueForHTTPHeaderField:@"methodname"];
    if ([url containsString:@"xiaocantech.com/rpc"] && [methodName isEqualToString:@"AdMobileService.MatchPlacement"]) {
        return YES;
    }

    // 2. 报告附录 A.3 的全部广告/ADX域名清单一网打尽
    static NSArray *adDomains = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        adDomains = @[
            @"leadmoad.com", @"adbiding.com", @"tobidad.cn", @"tobidad.com",
            @"sigmob.cn", @"pangolin-sdk", @"pglstatp-toutiao.com", @"ctobsnssdk.com",
            @"oceanengine.com", @"gdt.qq.com", @"e.qq.com", @"mobads.baidu.com",
            @"als.baidu.com", @"beizi.biz", @"adn-plus.com.cn", @"mentamob.com",
            @"fancydsp.com", @"fancyapi.com", @"dmrtb.com", @"richmob.cn",
            @"ubixioe.com", @"ad-scope.com.cn", @"tanx.com", @"1rtb.net",
            @"58iclick.com", @"iggrowth.cn", @"innotechx.com", @"etoolads.cn",
            @"zhangyuyidong.cn", @"hubcloud.com.cn", @"advlion.com", @"nwiztech.com",
            @"kuaishou.com", @"gifshow.com", @"bytescm.com"
        ];
    });

    for (NSString *domain in adDomains) {
        if ([url containsString:domain]) {
            return YES;
        }
    }
    return NO;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSString *url = self.request.URL.absoluteString;
    NSString *methodName = [self.request valueForHTTPHeaderField:@"methodname"];

    NSData *responseData = nil;
    if ([url containsString:@"xiaocantech.com/rpc"] && [methodName isEqualToString:@"AdMobileService.MatchPlacement"]) {
        // 针对业务网关，直接伪造 ad_open = 0，从源头掐断业务层调起开屏
        responseData = [@"{\"status\":{\"code\":0},\"data\":{\"ad_open\":0,\"ad_type\":[],\"ad_source\":[],\"ios_slot_id\":\"\"}}" dataUsingEncoding:NSUTF8StringEncoding];
    } else {
        // 针对第三方广告SDK，0秒返回标准空JSON，让SDK认为无填充立刻退出
        responseData = [@"{\"code\":0,\"ret\":107076,\"status_code\":20001,\"msg\":\"no ad\",\"data\":{}}" dataUsingEncoding:NSUTF8StringEncoding];
    }

    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                                              statusCode:200
                                                             HTTPVersion:@"HTTP/1.1"
                                                            headerFields:@{@"Content-Type": @"application/json; charset=utf-8"}];

    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:responseData];
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)stopLoading {
}

@end


// =========================================================================
// 模块二：绕过 Swift Direct Dispatch，在 UIView/UIWindow 层精准隐身与穿透
// 彻底干掉 LaunchUtil 的 launchView（大额红包图）与 AdSplash 的 adWindow
// =========================================================================

// 检查某个视图或其控制器是否属于开屏/闪屏兜底
static BOOL isSplashOrLaunchView(UIView *view) {
    if (!view) return NO;
    NSString *clsName = NSStringFromClass([view class]);

    // 命中报告 5.1 / 5.2 中的 LaunchView、AdSplash、Countdown、ForceClose 等视图
    if ([clsName localizedCaseInsensitiveContainsString:@"LaunchView"] ||
        [clsName localizedCaseInsensitiveContainsString:@"LaunchUtil"] ||
        [clsName localizedCaseInsensitiveContainsString:@"AdSplash"] ||
        [clsName localizedCaseInsensitiveContainsString:@"Splash"] ||
        [clsName localizedCaseInsensitiveContainsString:@"AdDYCountdown"] ||
        [clsName localizedCaseInsensitiveContainsString:@"TobidAdContainer"]) {
        return YES;
    }
    return NO;
}

%hook UIView

- (void)layoutSubviews {
    %orig;

    // 1. 如果当前 View 本身就是 LaunchView（大额红包）或 Splash 广告视图
    if (isSplashOrLaunchView(self)) {
        // 绝不调用 removeFromSuperview，防止 SnapKit equalToSuperview 断言闪退！
        // 直接透明 + 隐藏 + 关闭交互（点击直接穿透到底部首页）
        self.alpha = 0.0;
        self.hidden = YES;
        self.userInteractionEnabled = NO;
        return;
    }

    // 2. 深度检测：如果它是盖在 KeyWindow 上的全屏“大额红包”匿名 UIView 容器
    // 特征：父视图是 UIWindow，但自己不是 rootViewController.view，且里面包含全屏 ImageView
    if ([self.superview isKindOfClass:[UIWindow class]]) {
        UIWindow *win = (UIWindow *)self.superview;
        if (win.rootViewController && self != win.rootViewController.view) {
            NSString *clsName = NSStringFromClass([self class]);
            // 排除系统键盘、弹窗和 Flutter/Lynx 正常主容器
            if (![clsName hasPrefix:@"UITransitionView"] &&
                ![clsName hasPrefix:@"UIDropShadowView"] &&
                ![clsName containsString:@"Flutter"] &&
                ![clsName containsString:@"Toast"]) {

                self.alpha = 0.0;
                self.hidden = YES;
                self.userInteractionEnabled = NO;
            }
        }
    }
}

%end


// =========================================================================
// 模块三：精准打击报告 5.4 的“独立 UIWindow 覆盖”（adWindow）
// 触发状态机：“无合适窗口 / 窗口显示失败 -> 直接跳过开屏进入首页”
// =========================================================================

%hook UIWindow

- (void)makeKeyAndVisible {
    NSString *winCls = NSStringFromClass([self class]);
    NSString *rootVCCls = self.rootViewController ? NSStringFromClass([self.rootViewController class]) : @"";

    // 如果这个 Window 是广告独立窗口 (AdSplashMS / AdSplashWM 持有的 adWindow)
    if ([winCls localizedCaseInsensitiveContainsString:@"Ad"] ||
        [winCls localizedCaseInsensitiveContainsString:@"Splash"] ||
        [rootVCCls localizedCaseInsensitiveContainsString:@"Splash"] ||
        [rootVCCls localizedCaseInsensitiveContainsString:@"Ad"] ||
        self.windowLevel > UIWindowLevelNormal) {

        // 排除系统 Alert 窗口
        if (![winCls hasPrefix:@"_UIAlert"] && ![winCls hasPrefix:@"UIText"]) {
            self.hidden = YES;
            self.alpha = 0.0;
            self.userInteractionEnabled = NO;
            self.windowLevel = -1000.0;
            return; // 直接拦截，不让它成为 KeyWindow！
        }
    }
    %orig;
}

- (void)setHidden:(BOOL)hidden {
    if (!hidden) {
        NSString *winCls = NSStringFromClass([self class]);
        NSString *rootVCCls = self.rootViewController ? NSStringFromClass([self.rootViewController class]) : @"";
        if ([winCls localizedCaseInsensitiveContainsString:@"Ad"] ||
            [winCls localizedCaseInsensitiveContainsString:@"Splash"] ||
            [rootVCCls localizedCaseInsensitiveContainsString:@"Splash"]) {
            %orig(YES);
            self.alpha = 0.0;
            self.userInteractionEnabled = NO;
            return;
        }
    }
    %orig(hidden);
}

%end


// =========================================================================
// 模块四：底层 Runtime 动态解析 Swift 带命名空间的真实类 + 篡改配置键
// =========================================================================

// 拦截所有字典取值，强制命中报告 5.7 节列出的开屏配置键！
%hook NSDictionary

- (id)objectForKey:(id)aKey {
    if ([aKey isKindOfClass:[NSString class]]) {
        NSString *key = (NSString *)aKey;
        // 报告 5.7：全局忽略开屏
        if ([key isEqualToString:@"ignoreSplashAd"]) {
            return @(YES);
        }
        // 报告 5.7：新用户限制与关闭预加载
        if ([key isEqualToString:@"splash_disable_preload"] ||
            [key isEqualToString:@"limitNewUserSplashAd"]) {
            return @(YES);
        }
        // 报告 5.7：日展示频次上限全部设为 0（直接触发频控上限不展示！）
        if ([key isEqualToString:@"showFrequencyPerday"] ||
            [key isEqualToString:@"show_frequency_perday"] ||
            [key isEqualToString:@"imp_freq_by_day"] ||
            [key isEqualToString:@"imp_freq_by_hour"] ||
            [key isEqualToString:@"dailyDisplayLimit"] ||
            [key isEqualToString:@"ad_open"]) {
            return @(0);
        }
        // 报告 5.7：将 8 秒超时强制改为 0 秒
        if ([key isEqualToString:@"splash_timeout"] ||
            [key isEqualToString:@"splashReqTimeout"]) {
            return @(0);
        }
    }
    return %orig;
}

- (id) objectForKeyedSubscript:(id)key {
    if ([key isKindOfClass:[NSString class]]) {
        NSString *k = (NSString *)key;
        if ([k isEqualToString:@"ignoreSplashAd"] || [k isEqualToString:@"splash_disable_preload"]) return @(YES);
        if ([k isEqualToString:@"ad_open"] ||
            [k isEqualToString:@"showFrequencyPerday"] ||
            [k isEqualToString:@"show_frequency_perday"] ||
            [k isEqualToString:@"dailyDisplayLimit"]) return @(0);
        if ([k isEqualToString:@"splash_timeout"] || [k isEqualToString:@"splashReqTimeout"]) return @(0);
    }
    return %orig;
}

%end

// 拦截 NSUserDefaults，伪造报告 5.5 节的 ToBid 每日展示计数已满（比如已展示 9999 次）
%hook NSUserDefaults

- (NSInteger)integerForKey:(NSString *)defaultName {
    if ([defaultName isEqualToString:@"TOBID_SPLASH_COUNT"]) {
        return 99999; // 欺骗计数器：今天已经展示了99999次，触发频控直接跳过！
    }
    return %orig;
}

- (id)objectForKey:(NSString *)defaultName {
    if ([defaultName isEqualToString:@"TOBID_SPLASH_COUNT"]) {
        return @(99999);
    }
    return %orig;
}

%end


// =========================================================================
// 模块五：通杀各大主流 SDK 的 OC 开屏入口（报告 4.2 & 4.3 真实类名）
// =========================================================================

static void swizzleNoOp(Class cls, SEL sel) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (m) {
        method_setImplementation(m, imp_implementationWithBlock(^void(id self) {
            // 置空，直接短路
        }));
    }
}

// 注入 URLProtocol 到所有 Session 配置中（确保 Alamofire 和原生 Session 全部受控）
%hook NSURLSessionConfiguration

+ (NSURLSessionConfiguration *)defaultSessionConfiguration {
    NSURLSessionConfiguration *config = %orig;
    NSMutableArray *protocols = [config.protocolClasses mutableCopy];
    if (!protocols) protocols = [NSMutableArray array];
    [protocols insertObject:[XCFastPassProtocol class] atIndex:0];
    config.protocolClasses = protocols;
    return config;
}

+ (NSURLSessionConfiguration *)ephemeralSessionConfiguration {
    NSURLSessionConfiguration *config = %orig;
    NSMutableArray *protocols = [config.protocolClasses mutableCopy];
    if (!protocols) protocols = [NSMutableArray array];
    [protocols insertObject:[XCFastPassProtocol class] atIndex:0];
    config.protocolClasses = protocols;
    return config;
}

%end


%ctor {
    @autoreleasepool {
        // 1. 注册全局网络拦截器
        [NSURLProtocol registerClass:[XCFastPassProtocol class]];

        // 2. 预设 ToBid 开屏展示次数为 99999，利用频控自然跳过
        [[NSUserDefaults standardUserDefaults] setInteger:99999 forKey:@"TOBID_SPLASH_COUNT"];

        // 3. 动态扫描报告 4.2 / 4.3 / 5.1 中列出的所有真实 OC / Swift 类名并短路其加载方法
        dispatch_async(dispatch_get_main_queue(), ^{
            NSArray *splashClasses = @[
                // 报告 5.1 Swift 封装层（带模块前缀与不带前缀双保险）
                @"xiaocan.LaunchUtil", @"LaunchUtil",
                @"xiaocan.AdManager", @"AdManager",
                @"XiaoCanAd.AdSplash", @"AdSplash",
                @"XiaoCanAd.AdSplashWM", @"AdSplashWM",
                @"XiaoCanAd.AdSplashBU", @"AdSplashBU",
                @"XiaoCanAd.AdSplashMS", @"AdSplashMS",
                // 报告 4.2 & 4.3 聚合与直投 SDK 真实类名
                @"WindMillSplashAd", @"ABUAdSDKManager", @"ABUSplashAd",
                @"CSJSplashAd", @"BUNativeExpressSplashView", @"BUSplashAdView",
                @"GDTSplashAd", @"KSSplashAdView", @"BaiduMobAdSplash",
                @"MSSplashAd", @"LMSplashAd", @"AMPSSplashAd", @"AdScopeADNSplashAd",
                @"BeiZiSplash", @"OctAdSplash", @"QMSplashAd", @"UBiXSplashAd",
                @"FancySplashAd", @"DM_SplashAd", @"YTSplashAd", @"AdbidSplashAd",
                @"BTPSplashManager", @"MobPulseSplash"
            ];

            NSArray *noopSelectors = @[
                @"loadAd", @"loadAdData", @"loadAdAndShow", @"showAd",
                @"showSplashAd", @"loadSplashAd", @"showLaunchView",
                @"loadAdAndShowInWindow:", @"showInWindow:",
                @"showAdInWindow:withBottomView:", @"loadAndShowInWindow:"
            ];

            for (NSString *clsName in splashClasses) {
                Class cls = NSClassFromString(clsName);
                if (cls) {
                    for (NSString *selName in noopSelectors) {
                        swizzleNoOp(cls, NSSelectorFromString(selName));
                    }
                }
            }
        });
    }
}
