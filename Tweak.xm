#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ============================================================================
// 1. 定义全量广告域名黑名单（结合逆向报告与两次抓包的所有漏网之鱼）
// ============================================================================
static NSArray<NSString *> *kBlockedAdHosts = nil;

static BOOL isAdURL(NSURL *url) {
    if (!url || !url.host) return NO;
    NSString *host = url.host.lowercaseString;
    for (NSString *adDomain in kBlockedAdHosts) {
        if ([host containsString:adDomain]) {
            return YES;
        }
    }
    // 拦截明文 IP 的广告请求 (如抓包中的 198.18.0.48/sdk/req_ad 和 119.3.254.92)
    NSString *path = url.path.lowercaseString;
    if ([path containsString:@"/sdk/req_ad"] ||
        [path containsString:@"/ad/getad"] ||
        [path containsString:@"/infoconfig/"]) {
        return YES;
    }
    return NO;
}

// ============================================================================
// 2. 网络层釜底抽薪：直接 Hook NSURLSession 拦截并秒回空报错（消除超时等待！）
// ============================================================================
// 为什么之前开屏慢？因为把 URL 改成 127.0.0.1 会导致请求挂起等待连接超时。
// 现在的做法是：一旦发现是广告请求，如果带 completionHandler，直接立即回调 NSError！
// 这样广告 SDK 会在 0.001 秒内收到“加载失败”，瞬间触发 onSplashAdLoadFail 进入主页！

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData * _Nullable, NSURLResponse * _Nullable, NSError * _Nullable))completionHandler {
    if (request && isAdURL(request.URL)) {
        if (completionHandler) {
            NSError *cancelError = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                completionHandler(nil, nil, cancelError);
            });
        }
        // 返回一个空的 dummy task 防止崩溃，且绝不调用 resume 发送真实网络请求
        return %orig([NSURLRequest requestWithURL:[NSURL URLWithString:@"about:blank"]], nil);
    }
    return %orig;
}

- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url completionHandler:(void (^)(NSData * _Nullable, NSURLResponse * _Nullable, NSError * _Nullable))completionHandler {
    if (isAdURL(url)) {
        if (completionHandler) {
            NSError *cancelError = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                completionHandler(nil, nil, cancelError);
            });
        }
        return %orig([NSURL URLWithString:@"about:blank"], nil);
    }
    return %orig;
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    if (request && isAdURL(request.URL)) {
        return %orig([NSURLRequest requestWithURL:[NSURL URLWithString:@"about:blank"]]);
    }
    return %orig;
}

%end


// ============================================================================
// 3. UI 与控制器层通杀：不依赖 Swift 修饰符，直接从父类拦截所有开屏与广告视图
// ============================================================================

// A. 拦截所有开屏广告 ViewController (无论是 Swift 还是 ObjC 类，都必然继承自 UIViewController)
%hook UIViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    NSString *className = NSStringFromClass([self class]);

    // 匹配 YXSplashAdVC, YXSplashTakuAdVC 以及任何聚合 SDK 自带的 SplashVC
    if ([className containsString:@"Splash"] || [className containsString:@"splash"]) {
        NSLog(@">>> [AdBlock] 捕获到开屏控制器: %@，正在执行秒进销毁...", className);

        // 1. 立即隐藏视图，防止闪烁
        self.view.hidden = YES;
        self.view.alpha = 0.0;
        self.view.userInteractionEnabled = NO;

        // 2. 尝试调用控制器内部可能存在的跳过/关闭方法
        NSArray *skipSelectors = @[
            @"skipAction", @"closeAction", @"dismissAction",
            @"splashDidClose", @"onSplashAdLoadFail", @"removeSplashView"
        ];
        for (NSString *selStr in skipSelectors) {
            SEL sel = NSSelectorFromString(selStr);
            if ([self respondsToSelector:sel]) {
                ((void (*)(id, SEL))objc_msgSend)(self, sel);
            }
        }

        // 3. 如果它是模态弹出的，或者挂载在独立 UIWindow 上，直接销毁/移除
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.presentingViewController) {
                [self dismissViewControllerAnimated:NO completion:nil];
            }
            if (self.view.window && self.view.window != [UIApplication sharedApplication].delegate.window) {
                self.view.window.hidden = YES;
                self.view.window.rootViewController = nil;
            }
            [self.view removeFromSuperview];
            [self removeFromParentViewController];
        });
    }
}

%end

// B. 拦截所有信息流广告 Cell、Banner、悬浮球 (必然继承自 UIView)
%hook UIView

- (void)didMoveToSuperview {
    %orig;
    if (!self.superview) return;

    NSString *className = NSStringFromClass([self class]);
    // 匹配逆向报告中所有的自有与三方广告视图：
    // YXActivityNativeAdCell, YXEnergyNativeAdCell, YXOrderNativeAdCell, YXWithdrawNativeAdCell,
    // YXActDtlNativeAdView, YXAFPHomeAdView, YXHomeRootBottomAdView, YXAddonBringListBannerView,
    // WindMillNativeAdView, KSSplashAdView, CSJ*, GDT*, BeiZi* 等
    if ([className containsString:@"NativeAd"] ||
        [className containsString:@"HomeAdView"] ||
        [className containsString:@"BottomAdView"] ||
        [className containsString:@"BannerView"] ||
        [className containsString:@"Splash"] ||
        [className containsString:@"WindMill"] ||
        [className containsString:@"HXIcon"] ||
        [className containsString:@"AdGain"]) {

        self.hidden = YES;
        self.alpha = 0.0;
        self.userInteractionEnabled = NO;
        self.frame = CGRectZero;

        // 如果不是 UITableViewCell / UICollectionViewCell 本身，直接从父视图拔除
        if (![self isKindOfClass:[UITableViewCell class]] && ![self isKindOfClass:[UICollectionViewCell class]]) {
            [self removeFromSuperview];
        }
    }
}

- (void)layoutSubviews {
    %orig;
    NSString *className = NSStringFromClass([self class]);
    if ([className containsString:@"NativeAd"] ||
        [className containsString:@"HomeAdView"] ||
        [className containsString:@"BottomAdView"] ||
        [className containsString:@"BannerView"]) {
        self.hidden = YES;
        self.frame = CGRectZero;
    }
}

%end

// C. 针对信息流 TableView 中的广告 Cell 高度直接设为 0（消除空白占位）
%hook UITableView

- (UITableViewCell *)dequeueReusableCellWithIdentifier:(NSString *)identifier {
    UITableViewCell *cell = %orig;
    if (cell) {
        NSString *className = NSStringFromClass([cell class]);
        if ([className containsString:@"NativeAdCell"]) {
            cell.hidden = YES;
            cell.contentView.hidden = YES;
            cell.bounds = CGRectZero;
        }
    }
    return cell;
}

%end


// ============================================================================
// 4. 插件入口初始化 (%ctor)
// ============================================================================
%ctor {
    @autoreleasepool {
        // 初始化全量广告域名黑名单（涵盖报告与两次抓包的所有域名）
        kBlockedAdHosts = @[
            @"sigmob.cn",               // Sigmob / WindMill (tm.sigmob.cn, adservice.sigmob.cn, dc.sigmob.cn)
            @"anythinktech.com",        // TopOn / Taku (ujoy.anythinktech.com, tk.anythinktech.com)
            @"adgain.cn",               // AdGain (xadsmartget.adgain.cn)
            @"datads.cn",               // AdGain 上报 (adsmartget.datads.cn)
            @"pinyuconn.cn",            // AdGain 关联上报 (adsmartget.pinyuconn.cn)
            @"adbiding.com",            // 竞价与配置 (bid.adbiding.com, sdkconf.adbiding.com, sl.adbiding.com)
            @"adwangmai.com",           // 旺脉 (sdk.adx.adwangmai.com, sdk-cfg.adx.adwangmai.com)
            @"66mobi.com",              // 66mobi / Sigmob 关联 (sdk-track.66mobi.com)
            @"zhangyuyidong.cn",        // 章鱼广告 (sdk.zhangyuyidong.cn)
            @"beizi.biz",               // 倍孜 (sdk.beizi.biz, sdk-event.beizi.biz)
            @"adn-plus.com.cn",         // ADN+ (ad-api.adn-plus.com.cn, sdk-api.adn-plus.com.cn)
            @"1rtb.net",                // MSAd / 1RTB (sdk.1rtb.net)
            @"hubcloud.com.cn",         // HubCloud (sdktmp.hubcloud.com.cn)
            @"baihemob.com",            // 百合广告配置 (ad.baihemob.com, inner.baihemob.com)
            @"shunchangzhixing.com",    // 顺畅知行广告分发 (ad.shunchangzhixing.com)
            @"bwton.com",               // 广告上报 (ad.bwton.com)
            @"pangolin-sdk-toutiao",    // 穿山甲全系 (pangolin-sdk-toutiao.com, toutiao1.com, toutiao-b.com)
            @"pglstatp-toutiao.com",    // 穿山甲静态资源
            @"gdt.qq.com",              // 优量汇 (mi.gdt.qq.com, v2.gdt.qq.com, win.gdt.qq.com)
            @"e.qq.com",                // 腾讯广点通事件 (sdk.e.qq.com)
            @"ugdtimg.com",             // 广点通素材
            @"open.e.kuaishou.com",     // 快手联盟
            @"gdfp.gifshow.com",        // 快手指纹与反作弊
            @"mobads.baidu.com",        // 百度联盟
            @"cpro.baidustatic.com"     // 百度静态素材
        ];

        NSLog(@">>> [XiaoXiaoYouXuanAdBlock] Dylib 注入成功！已加载 %lu 条广告域名规则。", (unsigned long)kBlockedAdHosts.count);
    }
}
