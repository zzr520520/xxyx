#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreMotion/CoreMotion.h>
#import <objc/runtime.h>
#import <objc/message.h>

static CFAbsoluteTime kAppLaunchTime = 0;

// ============================================================================
// 2.8.3 找回"秒开"，同时不再动首页
// ----------------------------------------------------------------------------
// 分析报告结论：
//   * 开屏是"独立 UIWindow"（AdSplashMS/WM 各自持有 adWindow），不贴在 keyWindow 上；
//   * App 自带 LaunchUtil.launchView 兜底启动页（T0），这才是"不秒开"时你看到的画面；
//   * 参照实现 XCNoAdJump 只做网络拦截 + SDK swizzling + 禁传感器 + 外跳拦截。
// 2.8.2 用"精确类名"清图 → 首页正常，但启动页类名不带 Launch/Splash，所以又露出来了。
// 2.8.3 加回全屏大图清除，但上了一道安全闸门：
//   只有在"首页尚未挂载"（!gHomeMounted）时才清启动大图；一旦检测到首页内容（Flutter/
//   TabBar/WKWebView）就立刻永久停手，绝不再碰任何图。这样秒开回来了，首页也不会丢图。
// ============================================================================

static BOOL gHomeMounted = NO; // 首页是否已挂载；一旦为 YES 就永不清图

// 判断视图自身或任意祖先是否属于"启动页 / 开屏"命名族（精确词）
static BOOL isLaunchOrSplashView(UIView *view) {
    UIView *v = view;
    int depth = 0;
    while (v && depth < 12) {
        NSString *clsName = NSStringFromClass([v class]);
        if ([clsName containsString:@"Launch"] || [clsName containsString:@"Splash"]) {
            return YES;
        }
        v = v.superview;
        depth++;
    }
    return NO;
}

// 判断某个视图是否是真正的"首页容器"（包含 FlutterView / TabBar / WKWebView）
// 一旦命中就把 gHomeMounted 置位，之后所有清图逻辑立即失效
static BOOL isOrContainsHomeContent(UIView *view) {
    if (!view) return NO;
    NSString *clsName = NSStringFromClass([view class]);
    if ([clsName containsString:@"Flutter"] ||
        [clsName containsString:@"TabBar"] ||
        [clsName containsString:@"WKWebView"]) {
        gHomeMounted = YES;
        return YES;
    }
    UIResponder *next = [view nextResponder];
    if (next && [next isKindOfClass:[UIViewController class]]) {
        NSString *vcName = NSStringFromClass([next class]);
        if ([vcName containsString:@"Flutter"] ||
            [vcName containsString:@"TabBar"] ||
            [vcName containsString:@"Main"] ||
            [vcName containsString:@"Home"]) {
            gHomeMounted = YES;
            return YES;
        }
    }
    for (UIView *sub in view.subviews) {
        if (isOrContainsHomeContent(sub)) {
            gHomeMounted = YES;
            return YES;
        }
    }
    return NO;
}

// ============================================================================
// 1. 清空"启动大图"以恢复秒开；首页一挂载就永久停手，绝不碰首页图片
// ============================================================================
%hook UIImageView

- (void)setImage:(UIImage *)image {
    if (image && (CFAbsoluteTimeGetCurrent() - kAppLaunchTime < 6.0)) {
        BOOL shouldStrip = NO;

        // (a) 明确是启动/开屏命名族里的图 → 永远清（这类只在开屏出现）
        if (isLaunchOrSplashView(self)) {
            shouldStrip = YES;
        }
        // (b) 首页还没挂载时，全屏竖版大图 = 启动页大图 → 清；首页一出现这条就永久失效
        else if (!gHomeMounted && !isOrContainsHomeContent(self)) {
            CGSize imgSize = image.size;
            CGSize screenSize = [UIScreen mainScreen].bounds.size;
            BOOL isFullScreenImage =
                (imgSize.width >= screenSize.width * 0.8 && imgSize.height >= screenSize.height * 0.65) ||
                (imgSize.width >= 600 && imgSize.height >= 1000);
            if (isFullScreenImage) {
                shouldStrip = YES;
            }
        }
        // (c) 兜底：任何情况下都不允许在启动期"顺手"改首页的图
        if (shouldStrip && !isOrContainsHomeContent(self)) {
            // 只做透明化隐藏，绝不 removeFromSuperview，避免 SnapKit 布局断言闪退
            %orig(nil);
            self.hidden = YES;
            self.alpha = 0.0;
            self.userInteractionEnabled = NO;
            UIView *container = self.superview;
            if (container &&
                ![container isKindOfClass:[UIWindow class]] &&
                !isOrContainsHomeContent(container)) {
                container.hidden = YES;
                container.alpha = 0.0;
                container.userInteractionEnabled = NO;
            }
            return;
        }
    }
    %orig(image);
}

%end


// ============================================================================
// 2. 开屏窗口：只拦 SDK 自建的 Splash 窗口，不再用宽松的 "Ad" 子串匹配
// ============================================================================
%hook UIWindow

- (void)addSubview:(UIView *)view {
    // 关键修复：先正常加入，再按精确类名隐藏；绝不"丢弃"，避免首页子视图被吞掉导致白屏
    %orig(view);
    if (view && (CFAbsoluteTimeGetCurrent() - kAppLaunchTime < 6.0)) {
        NSString *clsName = NSStringFromClass([view class]);
        if ([clsName containsString:@"Launch"] || [clsName containsString:@"Splash"]) {
            view.hidden = YES;
            view.alpha = 0.0;
            view.userInteractionEnabled = NO;
        }
    }
}

- (void)makeKeyAndVisible {
    NSString *clsName = NSStringFromClass([self class]);
    NSString *rootVC = self.rootViewController ? NSStringFromClass([self.rootViewController class]) : @"";
    if ([clsName containsString:@"Splash"] || [rootVC containsString:@"Splash"]) {
        self.hidden = YES;
        self.alpha = 0.0;
        self.userInteractionEnabled = NO;
        return;
    }
    %orig;
}

%end


// ============================================================================
// 3. 启动窗口期内取消过渡动画（秒开），之后恢复原始行为
// ============================================================================
%hook UIViewController

- (void)viewWillAppear:(BOOL)animated {
    NSString *vcName = NSStringFromClass([self class]);

    // 首页控制器出现 → 永久关闭清图逻辑，之后绝不再碰任何图片
    if ([vcName containsString:@"Flutter"] || [vcName containsString:@"Main"] ||
        [vcName containsString:@"Home"] || [vcName containsString:@"TabBar"]) {
        gHomeMounted = YES;
    }

    if (CFAbsoluteTimeGetCurrent() - kAppLaunchTime < 6.0) {
        %orig(NO);
        if ([vcName containsString:@"Launch"] || [vcName containsString:@"Splash"]) {
            self.view.hidden = YES;
            self.view.alpha = 0.0;
        }
    } else {
        %orig(animated);
    }
}

%end


// ============================================================================
// 4. 只按精确类名隐藏已知广告/开屏视图（删除"全屏即隐藏"启发式，避免误伤首页容器）
// ============================================================================
%hook UIView

- (void)didMoveToSuperview {
    %orig;
    if (!self.superview) return;

    NSString *clsName = NSStringFromClass([self class]);
    if (!clsName) return;

    // 首页视图（Flutter/TabBar/WKWebView）挂载 → 永久关闭清图逻辑
    if ([clsName containsString:@"Flutter"] ||
        [clsName containsString:@"TabBar"] ||
        [clsName containsString:@"WKWebView"]) {
        gHomeMounted = YES;
    }

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
    }
}

%end


// ============================================================================
// 5. 网络层继续保持 100% 拦截所有第三方广告与小蚕 AdMobileService
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
    for (size_t i = 0; i < kBlockedAdHostsCount; i++) {
        if ([lowerHost containsString:kBlockedAdHosts[i]]) {
            return YES;
        }
    }
    return NO;
}

static BOOL isXiaoCanAdRPC(NSURLRequest *request) {
    if (!request || !request.URL) return NO;
    if (![[request.URL.absoluteString lowercaseString] containsString:@"gw.xiaocantech.com/rpc"]) return NO;
    NSString *methodName = [request valueForHTTPHeaderField:@"methodname"] ?: @"";
    NSString *serverName = [request valueForHTTPHeaderField:@"servername"] ?: @"";
    if ([methodName containsString:@"MatchPlacement"] || [methodName containsString:@"AdMobileService"] || [serverName isEqualToString:@"SilkwormAd"]) {
        return YES;
    }
    return NO;
}

@interface XCFastAdBlockProtocol : NSURLProtocol
@end

@implementation XCFastAdBlockProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if ([NSURLProtocol propertyForKey:@"XCAdHandled" inRequest:request]) return NO;
    if (isXiaoCanAdRPC(request) || shouldBlockAdURL(request.URL)) return YES;
    return NO;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }

- (void)startLoading {
    NSMutableURLRequest *mutableReq = [self.request mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:@"XCAdHandled" inRequest:mutableReq];
    if (isXiaoCanAdRPC(self.request)) {
        NSData *data = [@"{\"status\":{\"code\":0},\"data\":{\"ad_open\":0,\"ad_type\":[],\"ad_source\":[],\"ios_slot_id\":\"\",\"put_id\":0}}" dataUsingEncoding:NSUTF8StringEncoding];
        NSHTTPURLResponse *resp = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type": @"application/json"}];
        [self.client URLProtocol:self didReceiveResponse:resp cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        [self.client URLProtocol:self didLoadData:data];
        [self.client URLProtocolDidFinishLoading:self];
        return;
    }
    [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]];
}

- (void)stopLoading {}
@end

%hook NSURLSession
+ (NSURLSession *)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration delegate:(id<NSURLSessionDelegate>)delegate delegateQueue:(NSOperationQueue *)queue {
    if (configuration) {
        NSMutableArray *protocols = configuration.protocolClasses ? [configuration.protocolClasses mutableCopy] : [NSMutableArray array];
        if (![protocols containsObject:[XCFastAdBlockProtocol class]]) {
            [protocols insertObject:[XCFastAdBlockProtocol class] atIndex:0];
            configuration.protocolClasses = protocols;
        }
    }
    return %orig(configuration, delegate, queue);
}
%end

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
        kAppLaunchTime = CFAbsoluteTimeGetCurrent();
        [NSURLProtocol registerClass:[XCFastAdBlockProtocol class]];
    }
}
