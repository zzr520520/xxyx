#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// =========================================================================
// 1. 斩断主线程卡顿源头：禁用 BDASignalManager (防止启动时初始化 WKWebView 死锁)
// 对应崩溃日志 Thread 0 Frame 24~28 & 报告 4.4 节 BDASignalSDK
// =========================================================================
%hook BDASignalManager

+ (void)registerWithOptionalData:(id)data {
    // 直接置空，阻止字节跳动归因 SDK 在主线程创建 WKWebView 卡顿
}

- (void)preGetCachedData {
    // 置空
}

%end


// =========================================================================
// 2. 轻量级网络短路：不用 NSURLProtocol，直接在 Session 层秒回“无广告”
// =========================================================================

// 创建一个什么都不做的静默 Task，防止 SDK 报错重试
@interface XCDummyDataTask : NSURLSessionDataTask
@end
@implementation XCDummyDataTask
- (void)resume {}
- (void)cancel {}
- (void)suspend {}
- (NSURLSessionTaskState)state { return NSURLSessionTaskStateCompleted; }
@end

static BOOL isAdOrSplashRequest(NSURLRequest *request, BOOL *isMatchPlacement) {
    if (!request || !request.URL) return NO;
    NSString *url = request.URL.absoluteString;
    if (!url) return NO;

    // 检查是否为小蚕业务网关的开屏广告点位请求
    NSString *method = [request valueForHTTPHeaderField:@"methodname"];
    if (method && [method isEqualToString:@"AdMobileService.MatchPlacement"]) {
        if (isMatchPlacement) *isMatchPlacement = YES;
        return YES;
    }

    // 匹配报告附录 A.3 的广告域名
    static NSArray<NSString *> *domains = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        domains = @[
            @"leadmoad.com", @"adbiding.com", @"tobidad.cn", @"tobidad.com",
            @"sigmob.cn", @"pangolin-sdk", @"pglstatp-toutiao.com", @"ctobsnssdk.com",
            @"oceanengine.com", @"gdt.qq.com", @"e.qq.com", @"mobads.baidu.com",
            @"beizi.biz", @"adn-plus.com.cn", @"mentamob.com", @"fancydsp.com",
            @"fancyapi.com", @"dmrtb.com", @"richmob.cn", @"ubixioe.com",
            @"ad-scope.com.cn", @"1rtb.net", @"etoolads.cn", @"zhangyuyidong.cn",
            @"hubcloud.com.cn", @"advlion.com", @"nwiztech.com", @"open.e.kuaishou.com"
        ];
    });

    for (NSString *d in domains) {
        if ([url containsString:d]) {
            if (isMatchPlacement) *isMatchPlacement = NO;
            return YES;
        }
    }
    return NO;
}

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    BOOL isMatchPlacement = NO;
    if (isAdOrSplashRequest(request, &isMatchPlacement)) {
        if (completionHandler) {
            NSString *jsonStr = isMatchPlacement
                ? @"{\"status\":{\"code\":0},\"data\":{\"ad_open\":0,\"ad_type\":[],\"ad_source\":[],\"ios_slot_id\":\"\"}}"
                : @"{\"code\":0,\"ret\":107076,\"status_code\":20001,\"msg\":\"no ad\",\"data\":{}}";
            NSData *data = [jsonStr dataUsingEncoding:NSUTF8StringEncoding];
            NSHTTPURLResponse *resp = [[NSHTTPURLResponse alloc] initWithURL:request.URL
                                                                  statusCode:200
                                                                 HTTPVersion:@"HTTP/1.1"
                                                                headerFields:@{@"Content-Type": @"application/json"}];
            dispatch_async(dispatch_get_main_queue(), ^{
                completionHandler(data, resp, nil);
            });
        }
        // NSURLSessionDataTask 的 -init 在 iOS 13+ 被标记 deprecated，编译开启 -Werror 会报错；
        // 这里的哑任务只是占位对象，不会有真实网络行为，局部关闭该告警即可。
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        return [[XCDummyDataTask alloc] init];
#pragma clang diagnostic pop
    }
    return %orig;
}

%end


// =========================================================================
// 3. 彻底解决“大额红包”兜底闪屏 (LaunchView) 与三通道独立窗口 (adWindow)
// 不移除视图（防 SnapKit 崩溃），采用全透明 + 禁用交互穿透，瞬间直达并可操作首页！
// =========================================================================

%hook UIWindow

- (void)makeKeyAndVisible {
    NSString *cls = NSStringFromClass([self class]);
    NSString *rootCls = self.rootViewController ? NSStringFromClass([self.rootViewController class]) : @"";

    // 拦截报告 5.1 & 5.4 中 AdSplashMS / AdSplashWM 创建的独立 adWindow
    if ([cls localizedCaseInsensitiveContainsString:@"Splash"] ||
        [cls localizedCaseInsensitiveContainsString:@"AdWindow"] ||
        [rootCls localizedCaseInsensitiveContainsString:@"Splash"] ||
        [rootCls localizedCaseInsensitiveContainsString:@"Ad"]) {
        
        self.alpha = 0.0;
        self.hidden = YES;
        self.userInteractionEnabled = NO;
        return;
    }
    %orig;
}

- (void)didAddSubview:(UIView *)subview {
    %orig;
    if (!subview) return;

    // 当主窗口挂载子视图时，一旦发现不是主控制器视图（即盖在最上面的 LaunchView 大额红包图）
    // 延迟 0.05 秒等它完成 SnapKit 约束绑定后，立刻将其透明并允许点击穿透！
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.rootViewController && subview != self.rootViewController.view) {
            NSString *subCls = NSStringFromClass([subview class]);
            // 排除系统正常组件与 Flutter 主页面容器
            if (![subCls hasPrefix:@"UITransitionView"] &&
                ![subCls hasPrefix:@"UIDropShadowView"] &&
                ![subCls containsString:@"Flutter"] &&
                ![subCls containsString:@"Toast"]) {
                
                subview.alpha = 0.0;
                subview.hidden = YES;
                subview.userInteractionEnabled = NO;
            }
        }
    });
}

%end

%hook UIView

- (void)didMoveToWindow {
    %orig;
    if (!self.window) return;

    NSString *cls = NSStringFromClass([self class]);
    // 精准匹配报告 5.1 & 5.2 中的 LaunchView、AdSplash、Countdown、Tobid 容器
    if ([cls localizedCaseInsensitiveContainsString:@"LaunchView"] ||
        [cls localizedCaseInsensitiveContainsString:@"LaunchUtil"] ||
        [cls localizedCaseInsensitiveContainsString:@"AdSplash"] ||
        [cls localizedCaseInsensitiveContainsString:@"Splash"] ||
        [cls localizedCaseInsensitiveContainsString:@"AdDYCountdown"] ||
        [cls localizedCaseInsensitiveContainsString:@"TobidAdContainer"] ||
        [cls localizedCaseInsensitiveContainsString:@"ForceClose"]) {
        
        dispatch_async(dispatch_get_main_queue(), ^{
            self.alpha = 0.0;
            self.hidden = YES;
            self.userInteractionEnabled = NO;
        });
    }
}

%end


// =========================================================================
// 4. 加速开屏 8 秒超时定时器（报告 5.4：8秒超时强制关闭 -> 缩短为 0.01 秒立即触发关闭）
// =========================================================================
%hook NSTimer

+ (NSTimer *)scheduledTimerWithTimeInterval:(NSTimeInterval)ti target:(id)aTarget selector:(SEL)aSelector userInfo:(id)userInfo repeats:(BOOL)yesOrNo {
    if (ti >= 2.0 && ti <= 10.0 && !yesOrNo) {
        NSString *targetCls = aTarget ? NSStringFromClass([aTarget class]) : @"";
        NSString *selName = aSelector ? NSStringFromSelector(aSelector) : @"";
        if ([targetCls localizedCaseInsensitiveContainsString:@"Ad"] ||
            [targetCls localizedCaseInsensitiveContainsString:@"Splash"] ||
            [targetCls localizedCaseInsensitiveContainsString:@"Launch"] ||
            [selName localizedCaseInsensitiveContainsString:@"timeout"] ||
            [selName localizedCaseInsensitiveContainsString:@"splash"] ||
            [selName localizedCaseInsensitiveContainsString:@"dismiss"] ||
            [selName localizedCaseInsensitiveContainsString:@"close"]) {
            ti = 0.01;
        }
    }
    return %orig(ti, aTarget, aSelector, userInfo, yesOrNo);
}

%end


// =========================================================================
// 5. 初始化：利用报告 5.5 节的持久化频控键 + Runtime 置空各家 SDK 入口
// =========================================================================
static void disableMethod(Class cls, SEL sel) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (m) {
        method_setImplementation(m, imp_implementationWithBlock(^void(id self) {}));
    }
}

%ctor {
    @autoreleasepool {
        // 报告 5.5：把当日 ToBid 开屏展示次数设为 99999，并将重置日期设为今天，直接触发频控上限跳过！
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setInteger:99999 forKey:@"TOBID_SPLASH_COUNT"];
        [defaults setBool:YES forKey:@"ignoreSplashAd"];
        
        // 短路主流广告 SDK 的 OC 加载方法
        dispatch_async(dispatch_get_main_queue(), ^{
            NSArray *adClasses = @[
                @"WindMillSplashAd", @"ABUSplashAd", @"CSJSplashAd",
                @"BUNativeExpressSplashView", @"BUSplashAdView", @"GDTSplashAd",
                @"KSSplashAdView", @"BaiduMobAdSplash", @"MSSplashAd",
                @"LMSplashAd", @"AMPSSplashAd", @"AdScopeADNSplashAd",
                @"BeiZiSplash", @"OctAdSplash", @"QMSplashAd", @"UBiXSplashAd",
                @"FancySplashAd", @"DM_SplashAd", @"YTSplashAd", @"AdbidSplashAd"
            ];
            NSArray *selectors = @[
                @"loadAd", @"loadAdData", @"loadAdAndShow", @"showAd",
                @"loadAdAndShowInWindow:", @"showInWindow:", @"showAdInWindow:withBottomView:"
            ];
            for (NSString *clsName in adClasses) {
                Class cls = NSClassFromString(clsName);
                if (cls) {
                    for (NSString *selName in selectors) {
                        disableMethod(cls, NSSelectorFromString(selName));
                    }
                }
            }
        });
    }
}
