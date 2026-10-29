#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreMotion/CoreMotion.h>
#import <objc/runtime.h>
#import <objc/message.h>

static CFAbsoluteTime kAppLaunchTime = 0;

// ============================================================================
// 2.8.2 修复白屏 / 丢图
// ----------------------------------------------------------------------------
// 分析报告结论：
//   * 开屏是"独立 UIWindow"（AdSplashMS/WM 各自持有 adWindow），不贴在 keyWindow 上；
//   * App 自带 LaunchUtil.launchView 兜底启动页；
//   * 参照实现 XCNoAdJump 只做网络拦截 + SDK swizzling + 禁传感器 + 外跳拦截，从不碰视图层。
// 因此之前那套"任何全屏大图就清空 / 窗口已有首页就丢弃新子视图 / 隐藏所有非首页兄弟"的
// 广谱启发式，既把首页图片清掉（丢图），又把首页内容容器吞掉（白屏）。本版全部收窄为
// "精确类名匹配"，只隐藏启动/开屏命名族，绝不动首页。
// ============================================================================

// 判断视图自身或任意祖先是否属于"启动页 / 开屏"命名族（精确词，避免误伤首页图片）
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

// ============================================================================
// 1. 只清空"启动/开屏容器"里的图，保留秒开，绝不碰首页图片
// ============================================================================
%hook UIImageView

- (void)setImage:(UIImage *)image {
    if (image &&
        (CFAbsoluteTimeGetCurrent() - kAppLaunchTime < 6.0) &&
        isLaunchOrSplashView(self)) {
        // 只做透明化隐藏，绝不 removeFromSuperview，避免 SnapKit 布局断言闪退
        %orig(nil);
        self.hidden = YES;
        self.alpha = 0.0;
        self.userInteractionEnabled = NO;
        return;
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
    if (CFAbsoluteTimeGetCurrent() - kAppLaunchTime < 6.0) {
        %orig(NO);
        NSString *vcName = NSStringFromClass([self class]);
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
