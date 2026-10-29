#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ============================================================================
// 1. 纯 C 静态常量数组：直接固化在二进制数据段，永不释放，彻底告别野指针闪退！
// ============================================================================
static NSString * const kBlockedAdHosts[] = {
    @"sigmob.cn",               // Sigmob / WindMill
    @"anythinktech.com",        // TopOn / Taku
    @"adgain.cn",               // AdGain
    @"datads.cn",               // AdGain 上报
    @"pinyuconn.cn",            // AdGain 关联上报
    @"adbiding.com",            // 竞价与配置 (bid / sdkconf / sl)
    @"adwangmai.com",           // 旺脉 ADX
    @"66mobi.com",              // 66mobi / Sigmob 关联
    @"zhangyuyidong.cn",        // 章鱼广告
    @"beizi.biz",               // 倍孜广告
    @"adn-plus.com.cn",         // ADN+
    @"1rtb.net",                // MSAd / 1RTB
    @"hubcloud.com.cn",         // HubCloud
    @"baihemob.com",            // 百合广告配置
    @"shunchangzhixing.com",    // 顺畅知行广告分发
    @"bwton.com",               // 广告上报
    @"pangolin-sdk-toutiao",    // 穿山甲全系
    @"pglstatp-toutiao.com",    // 穿山甲静态资源
    @"gdt.qq.com",              // 优量汇 (mi / v2 / win)
    @"e.qq.com",                // 腾讯广点通事件
    @"ugdtimg.com",             // 广点通素材
    @"open.e.kuaishou.com",     // 快手联盟
    @"gdfp.gifshow.com",        // 快手指纹
    @"mobads.baidu.com",        // 百度联盟
    @"cpro.baidustatic.com"     // 百度静态素材
};

static const size_t kBlockedAdHostsCount = sizeof(kBlockedAdHosts) / sizeof(kBlockedAdHosts[0]);

static BOOL isAdURL(NSURL *url) {
    if (!url || ![url isKindOfClass:[NSURL class]]) return NO;

    NSString *host = [url host];
    if (host && [host isKindOfClass:[NSString class]] && host.length > 0) {
        NSString *lowerHost = [host lowercaseString];
        for (size_t i = 0; i < kBlockedAdHostsCount; i++) {
            if ([lowerHost containsString:kBlockedAdHosts[i]]) {
                return YES;
            }
        }
    }

    NSString *path = [url path];
    if (path && [path isKindOfClass:[NSString class]] && path.length > 0) {
        NSString *lowerPath = [path lowercaseString];
        if ([lowerPath containsString:@"/sdk/req_ad"] ||
            [lowerPath containsString:@"/ad/getad"] ||
            [lowerPath containsString:@"/infoconfig/"]) {
            return YES;
        }
    }
    return NO;
}

// 构造一个瞬间失败的本地请求（指向本地关闭的 0 端口，内核会立即返回 Connection Refused，耗时 < 1毫秒）
static NSURLRequest *createFastFailRequest(void) {
    NSURL *failURL = [NSURL URLWithString:@"http://127.0.0.1:0/ad_blocked"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:failURL
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:0.05];
    return req;
}

// ============================================================================
// 2. 网络层极速熔断：将广告请求替换为 0.05 秒超时的本地闭合端口请求
// ============================================================================
// 注意：不要把 completionHandler 传 nil，因为 Alamofire 等框架内部会对返回的 Task 绑定状态机，
// 保持原本的 completionHandler 并让系统底层瞬间报 Connection Refused，是最安全且绝不闪退的做法！

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData * _Nullable, NSURLResponse * _Nullable, NSError * _Nullable))completionHandler {
    if (request && [request isKindOfClass:[NSURLRequest class]] && isAdURL(request.URL)) {
        return %orig(createFastFailRequest(), completionHandler);
    }
    return %orig;
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    if (request && [request isKindOfClass:[NSURLRequest class]] && isAdURL(request.URL)) {
        return %orig(createFastFailRequest());
    }
    return %orig;
}

- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url completionHandler:(void (^)(NSData * _Nullable, NSURLResponse * _Nullable, NSError * _Nullable))completionHandler {
    if (isAdURL(url)) {
        NSURL *failURL = [NSURL URLWithString:@"http://127.0.0.1:0/ad_blocked"];
        return %orig(failURL, completionHandler);
    }
    return %orig;
}

%end


// ============================================================================
// 3. 开屏秒进与 UI 广告视图清理
// ============================================================================

%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    NSString *className = NSStringFromClass([self class]);
    if (!className) return;

    // 捕获开屏广告控制器 (YXSplashAdVC / YXSplashTakuAdVC 等)
    if ([className containsString:@"Splash"] || [className containsString:@"splash"]) {
        self.view.hidden = YES;
        self.view.alpha = 0.0;
        self.view.userInteractionEnabled = NO;

        // 尝试触发控制器自带的跳过或关闭回调
        NSArray<NSString *> *selectors = @[
            @"skipAction", @"closeAction", @"dismissAction",
            @"splashDidClose", @"onSplashAdLoadFail", @"removeSplashView"
        ];
        for (NSString *selName in selectors) {
            SEL sel = NSSelectorFromString(selName);
            if ([self respondsToSelector:sel]) {
                ((void (*)(id, SEL))objc_msgSend)(self, sel);
                break;
            }
        }

        // 安全移除独立开屏 Window 或模态控制器
        if (self.presentingViewController) {
            [self dismissViewControllerAnimated:NO completion:nil];
        } else if (self.view.window && self.view.window != [UIApplication sharedApplication].delegate.window) {
            self.view.window.hidden = YES;
        }
    }
}

%end

%hook UIView

- (void)layoutSubviews {
    %orig;
    NSString *className = NSStringFromClass([self class]);
    if (!className) return;

    // 隐藏自有业务层与聚合层的原生广告视图、Banner、悬浮窗
    if ([className containsString:@"NativeAd"] ||
        [className containsString:@"HomeAdView"] ||
        [className containsString:@"BottomAdView"] ||
        [className containsString:@"BannerView"] ||
        [className containsString:@"HXIcon"] ||
        [className containsString:@"WindMill"] ||
        [className containsString:@"AdGain"]) {

        self.hidden = YES;
        self.alpha = 0.0;
        self.userInteractionEnabled = NO;
        self.frame = CGRectZero;
    }
}

%end
