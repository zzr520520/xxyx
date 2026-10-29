#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ============================================================================
// 1. 纯 C 静态常量数组：覆盖《小蚕惠生活 3.21.6》逆向报告全部 60+ 广告域名根
// 固化在 __DATA_CONST 段，永不释放，彻底杜绝 EXC_BAD_ACCESS 野指针闪退
// ============================================================================
static NSString * const kXiaoCanBlockedHosts[] = {
    // --- 上层自有聚合中枢 (Adbid / Tobid / 乐盟) ---
    @"leadmoad.com",            // ads-bid.leadmoad.com, cdn.leadmoad.com
    @"tobidad.cn",              // c.tobidad.cn

    // --- 头部广告网络 (穿山甲 / 优量汇 / 快手 / 百度) ---
    @"pglstatp-toutiao.com",    // 穿山甲静态资源与模板
    @"pangolin-sdk-toutiao",    // 穿山甲全系请求域名
    @"gdt.qq.com",              // 腾讯优量汇
    @"e.qq.com",                // 广点通曝光上报
    @"ugdtimg.com",             // 广点通素材
    @"sparta.html5.qq.com",     // 腾讯 sparta 群事件上报
    @"open.e.kuaishou.com",     // 快手联盟请求
    @"gdfp.gifshow.com",        // 快手指纹
    @"mobads.baidu.com",        // 百度联盟主接口
    @"mobads-logs.baidu.com",   // 百度联盟日志
    @"cpu-openapi.baidu.com",   // 百度内容联盟
    @"cpu.baidu.com",           // 百度内容联盟
    @"pos.baidu.com",           // 百度点位上报 (wn.pos.baidu.com)
    @"bcebos.com",              // 百度预置配置 (mobads-pre-config / render-server)

    // --- 二线聚合与 RTB 网络 (趣盟 / 倍孜 / 迪莫 / 睿盟 / 盟推 / 美数 / 创信汇 / 欧克 / 风车 / Fancy / UBiX) ---
    @"yunxish.com",             // 趣盟 QMAdSDK (api / cpc-service-square / logrcv / service / show-api / cdn)
    @"58iclick.com",            // 趣盟同构域名
    @"iggrowth.cn",             // 趣盟同构域名
    @"innotechx.com",           // 趣盟备选域名 (fc / qf / fy / qfy)
    @"adn-plus.com.cn",         // 倍孜 ADN+ (sdk-api / ad-api)
    @"beizi.biz",               // 倍孜 (sdk / sdk-event / api-htp)
    @"ad-scope.com.cn",         // 倍孜备用 HTP (api.htp.ad-scope.com.cn)
    @"dmrtb.com",               // 迪莫 DMAdSDK (dmsdk-api / dmsdk-api-ssp / dmsdk-tracking)
    @"richmob.cn",              // 睿盟 RichmobAdSDK (sdkapi / adsdk)
    @"mentamob.com",            // 盟推 Menta (api-v3.mentamob.com)
    @"1rtb.com",                // 美数 MSAdSDK (sdk-report.1rtb.com)
    @"1rtb.net",                // 美数关联
    @"shunchangzhixing.com",    // 创信汇 CXHAdSDK (ad / inner / report)
    @"adintl.cn",               // 欧克 OctAdSDK (sdkcfg / test.s / www)
    @"zhangyuyidong.cn",        // 章鱼/欧克 (sdk / sdk6 / sdklog / iosid / iosid6)
    @"hubcloud.com.cn",         // 欧克离线日志 (sdktmp.hubcloud.com.cn)
    @"sigmob.cn",               // 风车 WindMill / Sigmob (tm / adservice / tbsasv / dc / tbiu / adxtool)
    @"fancyapi.com",            // Fancy RTB (g / t2 / static / lets / lftxali)
    @"ubixioe.com",             // UBiX ADX (adx-cfg-u1 / adx-data-u1 / entry-su1)
    @"vlion.cn",                // 瑞狮微联 ADX (bid-adx2.vlion.cn)
    @"xwpbj.com",               // 中介映射 (adprolink.xwpbj.com)
    @"baihemob.com",            // 百赫/白鹤 (ad.baihemob.com)
    @"etoolads.cn",             // Etool 配置 (c.etoolads.cn)
    @"ctdidcii.cn",             // CTD 落地页 (cdnrefresh.ctdidcii.cn)
    @"adgain.cn",               // AdGain (Richmob 桥接)
    @"adwangmai.com",           // 旺脉
    @"adbiding.com",            // 竞价上报

    // --- 广告归因与第三方监测 (不影响小蚕自身业务 gw.xiaocantech.com) ---
    @"oceanengine.com",         // 巨量引擎归因 (analytics.oceanengine.com)
    @"bdurl.net",               // 字节归因 (dig.bdurl.net)
    @"api-adservices.apple.com" // Apple AdServices 归因
};

static const size_t kXiaoCanBlockedHostsCount = sizeof(kXiaoCanBlockedHosts) / sizeof(kXiaoCanBlockedHosts[0]);

static BOOL isXiaoCanAdURL(NSURL *url) {
    if (!url || ![url isKindOfClass:[NSURL class]]) return NO;

    NSString *host = [url host];
    if (host && [host isKindOfClass:[NSString class]] && host.length > 0) {
        NSString *lowerHost = [host lowercaseString];
        // 确保绝不误伤小蚕自有业务网关与静态资源
        if ([lowerHost containsString:@"xiaocantech.com"] ||
            [lowerHost containsString:@"realtech-inc.com"] ||
            [lowerHost containsString:@"xinyifm.cn"] ||
            [lowerHost containsString:@"hzaiguojiang.com"] ||
            [lowerHost containsString:@"djtaoke.cn"]) {
            return NO;
        }

        for (size_t i = 0; i < kXiaoCanBlockedHostsCount; i++) {
            if ([lowerHost containsString:kXiaoCanBlockedHosts[i]]) {
                return YES;
            }
        }
    }

    // 拦截特征广告路径（防止部分 SDK 使用动态 IP 直连）
    NSString *path = [url path];
    if (path && [path isKindOfClass:[NSString class]] && path.length > 0) {
        NSString *lowerPath = [path lowercaseString];
        if ([lowerPath containsString:@"/api/v1/ad/"] ||
            [lowerPath containsString:@"/api/adx/"] ||
            [lowerPath containsString:@"/sdk/rtb/"] ||
            [lowerPath containsString:@"/mediation/sdk/"]) {
            return YES;
        }
    }
    return NO;
}

// 构造指向本地 0 端口的极速失败请求（内核立即返回 Connection Refused，消除开屏超时等待）
static NSURLRequest *createFastFailAdRequest(void) {
    NSURL *failURL = [NSURL URLWithString:@"http://127.0.0.1:0/xiaocan_ad_blocked"];
    return [NSMutableURLRequest requestWithURL:failURL
                                   cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                               timeoutInterval:0.05];
}


// ============================================================================
// 2. 网络层拦截：Hook NSURLSession 极速熔断所有开屏与竞价请求
// ============================================================================
%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData * _Nullable, NSURLResponse * _Nullable, NSError * _Nullable))completionHandler {
    if (request && [request isKindOfClass:[NSURLRequest class]] && isXiaoCanAdURL(request.URL)) {
        return %orig(createFastFailAdRequest(), completionHandler);
    }
    return %orig;
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    if (request && [request isKindOfClass:[NSURLRequest class]] && isXiaoCanAdURL(request.URL)) {
        return %orig(createFastFailAdRequest());
    }
    return %orig;
}

- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url completionHandler:(void (^)(NSData * _Nullable, NSURLResponse * _Nullable, NSError * _Nullable))completionHandler {
    if (isXiaoCanAdURL(url)) {
        NSURL *failURL = [NSURL URLWithString:@"http://127.0.0.1:0/xiaocan_ad_blocked"];
        return %orig(failURL, completionHandler);
    }
    return %orig;
}

%end


// ============================================================================
// 3. 拦截自有聚合层 AdbidSplashAd 及开屏展示逻辑
// ============================================================================

// 判断类名是否属于开屏广告 (Splash / AppOpen)
static BOOL isSplashClassName(NSString *className) {
    if (!className || className.length == 0) return NO;
    return ([className containsString:@"Splash"] ||
            [className containsString:@"splash"] ||
            [className containsString:@"AppOpen"] ||
            [className containsString:@"AdbidSplash"]);
}

// 拦截 NSObject 层面 Adbid / 各大 SDK 的 showAd: 与 loadAd 方法
%hook NSObject

// 报告 4.1 节还原出的 Adbid 核心展示方法：showAd:
- (void)showAd:(id)arg1 {
    NSString *className = NSStringFromClass([self class]);
    if (isSplashClassName(className) || [className hasPrefix:@"Adbid"] || [className hasPrefix:@"LMAd"]) {
        NSLog(@">>> [XiaoCanAdBlock] 成功拦截 %@ 调用 showAd:，直接跳过开屏！", className);
        return;
    }
    %orig;
}

// 报告 4.1 节还原出的 Adbid 核心加载方法：loadAdWithToken:
- (void)loadAdWithToken:(id)token {
    NSString *className = NSStringFromClass([self class]);
    if (isSplashClassName(className)) {
        NSLog(@">>> [XiaoCanAdBlock] 阻止开屏广告类 %@ 加载 Token", className);
        return;
    }
    %orig;
}

%end


// ============================================================================
// 4. UIViewController 与 UIView 层强行销毁开屏容器，实现秒进
// ============================================================================
%hook UIViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    NSString *className = NSStringFromClass([self class]);
    if (isSplashClassName(className)) {
        self.view.hidden = YES;
        self.view.alpha = 0.0;
        self.view.userInteractionEnabled = NO;
    }
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    NSString *className = NSStringFromClass([self class]);
    if (isSplashClassName(className)) {
        self.view.hidden = YES;
        self.view.alpha = 0.0;

        // 尝试触发跳过/关闭/隐藏回调（对应报告 4.5 节的 ad_hidden / ad_destory / ad_error）
        NSArray<NSString *> *closeSelectors = @[
            @"skipAction", @"closeAction", @"dismissAction",
            @"adDidClose", @"splashAdDidClose", @"onSplashAdLoadFail"
        ];
        for (NSString *selName in closeSelectors) {
            SEL sel = NSSelectorFromString(selName);
            if ([self respondsToSelector:sel]) {
                ((void (*)(id, SEL))objc_msgSend)(self, sel);
                break;
            }
        }

        if (self.presentingViewController) {
            [self dismissViewControllerAnimated:NO completion:nil];
        } else if (self.view.window && self.view.window != [UIApplication sharedApplication].delegate.window) {
            self.view.window.hidden = YES;
        }
    }
}

%end

%hook UIView

- (void)didMoveToSuperview {
    %orig;
    if (!self.superview) return;

    NSString *className = NSStringFromClass([self class]);
    if (!className) return;

    // 拦截所有开屏广告视图 (如 KSSplashAdView, CSJSplashView, GDTSplashView, AdbidSplash* 等)
    if (isSplashClassName(className)) {
        self.hidden = YES;
        self.alpha = 0.0;
        self.userInteractionEnabled = NO;
        self.frame = CGRectZero;

        // 如果是挂载在独立广告 Window 上，连同非主 Window 一起隐藏
        if (self.window && self.window != [UIApplication sharedApplication].delegate.window &&
            [NSStringFromClass([self.window class]) containsString:@"Splash"]) {
            self.window.hidden = YES;
        }

        [self removeFromSuperview];
    }
}

- (void)layoutSubviews {
    %orig;
    NSString *className = NSStringFromClass([self class]);
    if (isSplashClassName(className)) {
        self.hidden = YES;
        self.alpha = 0.0;
        self.frame = CGRectZero;
    }
}

%end
