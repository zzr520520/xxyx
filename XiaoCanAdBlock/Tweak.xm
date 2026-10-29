#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreMotion/CoreMotion.h>
#import <objc/runtime.h>
#import <objc/message.h>

static CFAbsoluteTime kAppLaunchTime = 0;

// ============================================================================
// 1. 判断某个视图是否是真正的“首页容器”（包含 FlutterView 或 TabBar）
// 小蚕的首页是 Flutter 引擎渲染的 (FlutterViewController / FlutterView)
// ============================================================================
static BOOL isOrContainsHomeContent(UIView *view) {
    if (!view) return NO;
    NSString *clsName = NSStringFromClass([view class]);
    if ([clsName containsString:@"Flutter"] || 
        [clsName containsString:@"TabBar"] ||
        [clsName containsString:@"WKWebView"]) {
        return YES;
    }
    UIResponder *next = [view nextResponder];
    if (next && [next isKindOfClass:[UIViewController class]]) {
        NSString *vcName = NSStringFromClass([next class]);
        if ([vcName containsString:@"Flutter"] || 
            [vcName containsString:@"TabBar"] || 
            [vcName containsString:@"Main"] ||
            [vcName containsString:@"Home"]) {
            return YES;
        }
    }
    for (UIView *sub in view.subviews) {
        if (isOrContainsHomeContent(sub)) {
            return YES;
        }
    }
    return NO;
}

// ============================================================================
// 2. 第一刀：在本地容器加载启动图片时，直接抹除所有全屏启动大图！
// 无论它是 LaunchImage、Assets.car 里的本地内置图，还是沙盒缓存的红包图，
// 只要在启动前 5 秒内尝试往 UIImageView 里塞入全屏尺寸的大图，当场清空！
// ============================================================================
%hook UIImageView

- (void)setImage:(UIImage *)image {
    if (image && (CFAbsoluteTimeGetCurrent() - kAppLaunchTime < 5.0)) {
        CGSize imgSize = image.size;
        CGSize screenSize = [UIScreen mainScreen].bounds.size;
        
        // 判断是否为全屏竖版开屏图/背景图（宽高接近屏幕尺寸，或像素尺寸 >= 600x1000）
        BOOL isFullScreenImage = (imgSize.width >= screenSize.width * 0.8 && imgSize.height >= screenSize.height * 0.65) ||
                                 (imgSize.width >= 600 && imgSize.height >= 1000);
        
        if (isFullScreenImage && !isOrContainsHomeContent(self)) {
            // 安全更新：只做透明化隐藏，绝不 removeFromSuperview，避免 SnapKit 布局断言闪退！
            %orig(nil);
            self.hidden = YES;
            self.alpha = 0.0;
            self.userInteractionEnabled = NO;
            if (self.superview && !isOrContainsHomeContent(self.superview)) {
                self.superview.hidden = YES;
                self.superview.alpha = 0.0;
                self.superview.userInteractionEnabled = NO;
            }
            return;
        }
    }
    %orig(image);
}

- (void)layoutSubviews {
    %orig;
    // 双重保险：如果 UIImageView 是通过 Storyboard / XIB / Swift 初始化直接赋值的图片（没走 setImage:）
    if (self.image && (CFAbsoluteTimeGetCurrent() - kAppLaunchTime < 5.0)) {
        CGSize screenSize = [UIScreen mainScreen].bounds.size;
        if (self.bounds.size.width >= screenSize.width * 0.85 &&
            self.bounds.size.height >= screenSize.height * 0.65 &&
            !isOrContainsHomeContent(self)) {
            
            self.image = nil;
            self.hidden = YES;
            self.alpha = 0.0;
            self.userInteractionEnabled = NO;
            
            // 安全更新：连同装着它的本地容器 View 一起透明化隐藏，绝不 removeFromSuperview！
            UIView *container = self.superview;
            if (container && ![container isKindOfClass:[UIWindow class]] && !isOrContainsHomeContent(container)) {
                container.hidden = YES;
                container.alpha = 0.0;
                container.userInteractionEnabled = NO;
            }
        }
    }
}

%end


// ============================================================================
// 3. 第二刀：直接从 UIWindow 容器中铲除盖在 Flutter 首页上面的本地遮罩层！
// 报告 5.2 节指出：LaunchUtil.$__lazy_storage_$_launchView 会被加到窗口容器里盖住首页。
// 我们在 UIWindow 每次布局（layoutSubviews）和添加子视图时，只要看到 Flutter 首页已经存在，
// 就把所有挡在 FlutterView 上面的遮罩层（无论它叫什么名字）全部当场删除！
// ============================================================================
static void cleanBlockingContainersInWindow(UIWindow *window) {
    if (!window) return;
    
    // 1. 检查 window 的直接子视图
    UIView *flutterContainer = nil;
    for (UIView *sub in window.subviews) {
        if (isOrContainsHomeContent(sub)) {
            flutterContainer = sub;
            break;
        }
    }
    
    // 如果主窗口里已经有首页容器了，任何排在它后面的全屏遮罩层（就是那个内置启动页容器！）立刻删掉！
    if (flutterContainer) {
        for (UIView *sub in [window.subviews copy]) {
            if (sub != flutterContainer && !isOrContainsHomeContent(sub)) {
                NSString *clsName = NSStringFromClass([sub class]);
                if (![clsName hasPrefix:@"_UI"] && ![clsName hasPrefix:@"UITransition"] && ![clsName hasPrefix:@"UILayoutContainer"]) {
                    sub.hidden = YES;
                    sub.alpha = 0.0;
                    sub.userInteractionEnabled = NO;
                }
            }
        }
    }
    
    // 2. 检查 window.rootViewController.view 内部的子视图（防止 LaunchView 是加在 rootVC.view 上的！）
    if (window.rootViewController && window.rootViewController.isViewLoaded) {
        UIView *rootView = window.rootViewController.view;
        UIView *innerFlutter = nil;
        for (UIView *sub in rootView.subviews) {
            if (isOrContainsHomeContent(sub)) {
                innerFlutter = sub;
                break;
            }
        }
        if (innerFlutter) {
            for (UIView *sub in [rootView.subviews copy]) {
                if (sub != innerFlutter && !isOrContainsHomeContent(sub)) {
                    sub.hidden = YES;
                    sub.alpha = 0.0;
                    sub.userInteractionEnabled = NO;
                }
            }
        }
    }
}

%hook UIWindow

- (void)addSubview:(UIView *)view {
    if (view && (CFAbsoluteTimeGetCurrent() - kAppLaunchTime < 6.0)) {
        NSString *clsName = NSStringFromClass([view class]);
        // 凡是名字带 Launch / Splash / Ad 的本地容器，直接禁止加进 Window！
        if ([clsName containsString:@"Launch"] || 
            [clsName containsString:@"Splash"] || 
            [clsName containsString:@"AdSplash"]) {
            view.hidden = YES;
            view.alpha = 0.0;
            return;
        }
        // 如果当前 Window 已经有首页（FlutterView），拒绝任何新的全屏非系统 View 盖上来！
        if (isOrContainsHomeContent(self) && !isOrContainsHomeContent(view)) {
            if (![clsName hasPrefix:@"UI"] && ![clsName hasPrefix:@"_UI"]) {
                view.hidden = YES;
                view.alpha = 0.0;
                return;
            }
        }
    }
    %orig(view);
    if (CFAbsoluteTimeGetCurrent() - kAppLaunchTime < 6.0) {
        cleanBlockingContainersInWindow(self);
    }
}

- (void)layoutSubviews {
    %orig;
    if (CFAbsoluteTimeGetCurrent() - kAppLaunchTime < 6.0) {
        cleanBlockingContainersInWindow(self);
    }
}

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

%end


// ============================================================================
// 4. 第三刀：如果内置页面是一个独立的 UIViewController 容器，直接跳过它！
// ============================================================================
%hook UIViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig(NO); // 启动期取消一切过渡动画，瞬间显现
    if (CFAbsoluteTimeGetCurrent() - kAppLaunchTime < 6.0) {
        NSString *vcName = NSStringFromClass([self class]);
        if ([vcName containsString:@"Launch"] || 
            [vcName containsString:@"Splash"] || 
            [vcName containsString:@"AdSplash"]) {
            self.view.hidden = YES;
            self.view.alpha = 0.0;
            if (self.presentingViewController) {
                [self dismissViewControllerAnimated:NO completion:nil];
            }
        }
    }
}

- (void)presentViewController:(UIViewController *)viewControllerToPresent animated:(BOOL)flag completion:(void (^)(void))completion {
    if (viewControllerToPresent && (CFAbsoluteTimeGetCurrent() - kAppLaunchTime < 6.0)) {
        NSString *vcName = NSStringFromClass([viewControllerToPresent class]);
        if ([vcName containsString:@"Launch"] || 
            [vcName containsString:@"Splash"] || 
            [vcName containsString:@"Ad"]) {
            if (completion) completion();
            return;
        }
    }
    %orig;
}

%end


// ============================================================================
// 5. 拦截所有 UIView 容器挂载（消灭信息流广告与残余开屏组件）
// ============================================================================
%hook UIView

- (void)didMoveToSuperview {
    %orig;
    if (!self.superview) return;
    
    NSString *clsName = NSStringFromClass([self class]);
    if (!clsName) return;
    
    // 删掉任何名为 Launch / Splash / Ad 的视图容器
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
        return;
    }
    
    // 如果父视图已经包含了 Flutter 首页，绝不允许任何非 Flutter 的全屏容器盖在上面！
    if (CFAbsoluteTimeGetCurrent() - kAppLaunchTime < 6.0) {
        CGSize screenSize = [UIScreen mainScreen].bounds.size;
        if (self.bounds.size.width >= screenSize.width * 0.85 &&
            self.bounds.size.height >= screenSize.height * 0.65) {
            if (isOrContainsHomeContent(self.superview) && !isOrContainsHomeContent(self)) {
                self.hidden = YES;
                self.alpha = 0.0;
                self.userInteractionEnabled = NO;
            }
        }
    }
}

%end


// ============================================================================
// 6. 网络层继续保持 100% 拦截所有第三方广告与小蚕 AdMobileService
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
