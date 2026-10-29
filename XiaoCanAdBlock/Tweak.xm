#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreMotion/CoreMotion.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ============================================================================
// 1. 全量广告域名黑名单 (纯 C 静态常量数组，固化在 __DATA_CONST，永不释放防闪退)
// 结合最新报告附录 A.3 与最新抓包日志补齐所有变种域名
// ============================================================================
static NSString * const kBlockedAdHosts[] = {
    @"leadmoad.com",            // 含 ads-bid.leadmoad.com 及最新抓包的 adsbid.leadmoad.com
    @"adbiding.com",            // sdkconf.adbiding.com, sl.adbiding.com
    @"tobidad.cn",              // c.tobidad.cn
    @"tobidad.com",
    @"sigmob.cn",               // tm.sigmob.cn, dc.sigmob.cn, adservice.sigmob.cn
    @"pangolin-sdk-toutiao",    // 穿山甲全系 (pangolin-sdk-toutiao.com / toutiao1.com)
    @"pglstatp-toutiao.com",    // 穿山甲静态资源
    @"ctobsnssdk.com",          // 字节设备注册与日志 (toblog.ctobsnssdk.com)
    @"oceanengine.com",         // 巨量归因 (analytics.oceanengine.com)
    @"bdurl.net",               // dig.bdurl.net
    @"bytescm.com",             // 穿山甲试玩组件 (lf-cdn-tos.bytescm.com)
    @"bytegoofy.com",
    @"gdt.qq.com",              // 优量汇 (mi.gdt.qq.com, c2.gdt.qq.com, win.gdt.qq.com, v2.gdt.qq.com)
    @"e.qq.com",                // sdk.e.qq.com
    @"ugdtimg.com",             // 广点通图片/视频素材 (pgdt.ugdtimg.com, adsmind.ugdtimg.com)
    @"gdtimg.com",
    @"sparta.html5.qq.com",
    @"mobads.baidu.com",        // 百度联盟
    @"mobads-logs.baidu.com",
    @"als.baidu.com",
    @"cpu-openapi.baidu.com",
    @"pos.baidu.com",
    @"bcebos.com",
    @"beizi.biz",               // 倍孜 (sdk.beizi.biz, sdk-event.beizi.biz, api-htp.beizi.biz)
    @"adn-plus.com.cn",
    @"ad-scope.com.cn",         // 倍孜 AdScope
    @"mentamob.com",            // 盟推 Menta (api-v3.mentamob.com, api-nxs-v3/v4.mentamob.com)
    @"advlion.com",             // 最新抓包：盟推/瑞狮上报 (bj-td-menta-01-callback.advlion.com, td-nexus.advlion.com)
    @"vlion.cn",
    @"fibo.cn",                 // 盟推关联 (kbsvr.fibo.cn)
    @"fancydsp.com",            // 最新抓包：Fancy (mpcfg.fancydsp.com)
    @"fancyapi.com",            // 最新抓包：t2.fancyapi.com, g.fancyapi.com
    @"dmrtb.com",               // 多盟/迪莫 (dmsdk-api.dmrtb.com)
    @"richmob.cn",              // 互裕/睿盟 (adsdk.richmob.cn)
    @"ubixioe.com",             // UBiX
    @"tanx.com",                // 阿里妈妈 Tanx
    @"1rtb.net",                // 最新抓包：美数 MSAdSDK (sdk.1rtb.net)
    @"1rtb.com",
    @"yunxish.com",             // 趣盟 QM
    @"58iclick.com",
    @"iggrowth.cn",
    @"innotechx.com",
    @"etoolads.cn",
    @"zhangyuyidong.cn",        // 最新抓包：章鱼/Octopus (sdk.zhangyuyidong.cn)
    @"adintl.cn",
    @"hubcloud.com.cn",         // 最新抓包：sdktmp.hubcloud.com.cn
    @"nwiztech.com",            // 有推 YouTui (yyz-api.nwiztech.com)
    @"shunchangzhixing.com",    // 创信汇
    @"baihemob.com",
    @"xwpbj.com",
    @"open.e.kuaishou.com",     // 快手联盟
    @"gdfp.gifshow.com"
};

static const size_t kBlockedAdHostsCount = sizeof(kBlockedAdHosts) / sizeof(kBlockedAdHosts[0]);

static BOOL isAdRequestURL(NSURL *url) {
    if (!url || ![url isKindOfClass:[NSURL class]]) return NO;
    NSString *host = [url host];
    if (!host || ![host isKindOfClass:[NSString class]] || host.length == 0) return NO;

    NSString *lowerHost = [host lowercaseString];

    // 白名单保护：绝不拦截小蚕核心业务网关与图片 CDN
    if ([lowerHost containsString:@"xiaocantech.com"] ||
        [lowerHost containsString:@"realtech-inc.com"] ||
        [lowerHost containsString:@"xinyifm.cn"] ||
        [lowerHost containsString:@"hzaiguojiang.com"] ||
        [lowerHost containsString:@"djtaoke.cn"]) {
        return NO;
    }

    for (size_t i = 0; i < kBlockedAdHostsCount; i++) {
        if ([lowerHost containsString:kBlockedAdHosts[i]]) {
            return YES;
        }
    }
    return NO;
}

// ============================================================================
// 2. 自定义 NSURLProtocol 底层拦截器 (复刻报告 3.2 节 XCAdBlock 机制)
// 在 CFNetwork 协议层直接秒拒所有广告域名，耗时 < 0.1ms，无任何超时等待
// ============================================================================
@interface XCFastAdBlockProtocol : NSURLProtocol
@end

@implementation XCFastAdBlockProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if ([NSURLProtocol propertyForKey:@"XCFastAdHandled" inRequest:request]) {
        return NO;
    }
    if (isAdRequestURL(request.URL)) {
        return YES;
    }
    // 拦截小蚕业务网关里拉取广告位的 RPC 请求 (AdMobileService.MatchPlacement)
    if (request.URL && [[request.URL.absoluteString lowercaseString] containsString:@"gw.xiaocantech.com/rpc"]) {
        NSString *methodName = [request valueForHTTPHeaderField:@"methodname"];
        if (methodName && [methodName containsString:@"AdMobileService"]) {
            return YES;
        }
    }
    return NO;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSMutableURLRequest *mutableReq = [self.request mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:@"XCFastAdHandled" inRequest:mutableReq];

    // 如果是小蚕自己的 AdMobileService RPC，返回合法的空 JSON 让它立即认为“无广告开启”
    if (self.request.URL && [[self.request.URL.absoluteString lowercaseString] containsString:@"gw.xiaocantech.com/rpc"]) {
        NSData *fakeData = [@"{\"status\":{\"code\":0},\"data\":{\"ad_open\":0,\"ad_type\":[],\"ad_source\":[]}}" dataUsingEncoding:NSUTF8StringEncoding];
        NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                                                  statusCode:200
                                                                 HTTPVersion:@"HTTP/1.1"
                                                                headerFields:@{@"Content-Type": @"application/json"}];
        [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        [self.client URLProtocol:self didLoadData:fakeData];
        [self.client URLProtocolDidFinishLoading:self];
        return;
    }

    // 其他三方广告域名直接秒抛 Cancelled 错误，迫使三通道状态机瞬间流转到“加载失败->跳过开屏”
    NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil];
    [self.client URLProtocol:self didFailWithError:error];
}

- (void)stopLoading {
}

@end

// 确保 NSURLSessionConfiguration 始终挂载我们的 Protocol (防止 Alamofire 等自带 Session 绕过)
%hook NSURLSessionConfiguration

- (NSArray *)protocolClasses {
    NSArray *orig = %orig;
    NSMutableArray *protocols = orig ? [orig mutableCopy] : [NSMutableArray array];
    if (![protocols containsObject:[XCFastAdBlockProtocol class]]) {
        [protocols insertObject:[XCFastAdBlockProtocol class] atIndex:0];
    }
    return protocols;
}

%end


// ============================================================================
// 3. 强杀 LaunchUtil 的兜底闪屏 LaunchView 与三通道独立 adWindow (解决“大额红包”卡屏的核心！)
// 报告 5.1 & 5.2 节指出：T0 阶段由 LaunchUtil.$__lazy_storage_$_launchView 展示兜底闪屏，
// T4 阶段由 AdSplashMS / AdSplashWM / AdSplashBU 的独立 adWindow 覆盖全屏。
// ============================================================================

// 辅助函数：立刻隐藏并清空指定对象的 launchView 或 adWindow 成员变量
static void nukeSplashIvars(id obj) {
    if (!obj) return;
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList([obj class], &count);
    if (!ivars) return;

    for (unsigned int i = 0; i < count; i++) {
        const char *name = ivar_getName(ivars[i]);
        if (!name) continue;
        NSString *ivarName = [NSString stringWithUTF8String:name];

        // 1. 强开 ignoreSplashAd / isClose 标志位
        if ([ivarName containsString:@"ignoreSplashAd"] || [ivarName containsString:@"isClose"]) {
            const char *type = ivar_getTypeEncoding(ivars[i]);
            if (type && (strcmp(type, "B") == 0 || strcmp(type, "c") == 0)) {
                *((BOOL *)((char *)obj + ivar_getOffset(ivars[i]))) = YES;
            }
        }

        // 2. 销毁 launchView / adWindow / splashAd / dyCountdownView
        if ([ivarName containsString:@"launchView"] ||
            [ivarName containsString:@"adWindow"] ||
            [ivarName containsString:@"dyCountdownView"] ||
            [ivarName containsString:@"customSplashView"]) {
            const char *type = ivar_getTypeEncoding(ivars[i]);
            if (type && type[0] == '@') {
                id val = object_getIvar(obj, ivars[i]);
                if (val && [val isKindOfClass:[UIView class]]) {
                    UIView *v = (UIView *)val;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        v.hidden = YES;
                        v.alpha = 0.0;
                        v.userInteractionEnabled = NO;
                        if ([v isKindOfClass:[UIWindow class]]) {
                            ((UIWindow *)v).rootViewController = nil;
                        } else {
                            [v removeFromSuperview];
                        }
                    });
                }
            }
        }
    }
    free(ivars);
}

// 拦截独立广告 UIWindow 的显示 (报告 5.4 节：AdSplashMS / AdSplashWM 另起 UIWindow 覆盖首页)
%hook UIWindow

- (void)makeKeyAndVisible {
    NSString *className = NSStringFromClass([self class]);
    NSString *rootVCName = self.rootViewController ? NSStringFromClass([self.rootViewController class]) : @"";

    // 如果 Window 本身或它的 RootVC 是 Splash / Ad 相关，或者是高于 Normal 层级的广告遮罩窗
    if ([className containsString:@"Splash"] || [className containsString:@"Ad"] ||
        [rootVCName containsString:@"Splash"] || [rootVCName containsString:@"AdSplash"]) {
        self.hidden = YES;
        self.alpha = 0.0;
        self.userInteractionEnabled = NO;
        return;
    }
    %orig;
}

- (void)setHidden:(BOOL)hidden {
    if (!hidden) {
        NSString *className = NSStringFromClass([self class]);
        NSString *rootVCName = self.rootViewController ? NSStringFromClass([self.rootViewController class]) : @"";
        if ([className containsString:@"Splash"] || [rootVCName containsString:@"Splash"] || [rootVCName containsString:@"AdSplash"]) {
            %orig(YES);
            return;
        }
    }
    %orig;
}

%end

// 拦截 LaunchView（即“大额红包在小蚕”那张全屏启动图）以及所有 AdSplash 视图
%hook UIView

- (void)didMoveToSuperview {
    %orig;
    if (!self.superview) return;

    NSString *className = NSStringFromClass([self class]);
    if (!className) return;

    // 1. 精准命中报告 5.1 & 5.2 节还原出的 LaunchView / AdSplash / AdDYCountdownView / 信息流广告视图
    if ([className containsString:@"LaunchView"] ||
        [className containsString:@"Launch"] ||
        [className containsString:@"AdSplash"] ||
        [className containsString:@"Splash"] ||
        [className containsString:@"AdDYCountdownView"] ||
        [className containsString:@"AdNativeView"] ||
        [className containsString:@"OrderAdCell"] ||
        [className containsString:@"MineNativeAdCell"] ||
        [className containsString:@"HXIconAdView"] ||
        [className containsString:@"LynxTobidFeedAdView"]) {

        // 排除系统自带的 UILaunchScreenController 内部普通基础容器，只杀自定义 LaunchView 与 Ad 视图
        if (![className hasPrefix:@"UI"] && ![className hasPrefix:@"_UI"]) {
            self.hidden = YES;
            self.alpha = 0.0;
            self.userInteractionEnabled = NO;
            self.frame = CGRectZero;

            if (![self isKindOfClass:[UITableViewCell class]] && ![self isKindOfClass:[UICollectionViewCell class]]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self removeFromSuperview];
                });
            }
            return;
        }
    }

    // 2. 启发式檢測：如果某个全屏 View 内部包含了“该花花 该省省”或“大额红包在小蚕”的兜底图/文字，立即移除
    if (CGRectGetWidth(self.bounds) >= [UIScreen mainScreen].bounds.size.width * 0.9 &&
        CGRectGetHeight(self.bounds) >= [UIScreen mainScreen].bounds.size.height * 0.8) {
        NSString *superName = NSStringFromClass([self.superview class]);
        if ([superName isEqualToString:@"UIWindow"] || [superName containsString:@"Launch"]) {
            for (UIView *sub in self.subviews) {
                NSString *subClass = NSStringFromClass([sub class]);
                if ([subClass containsString:@"Launch"] || [subClass containsString:@"Splash"] || [subClass containsString:@"Ad"]) {
                    self.hidden = YES;
                    self.alpha = 0.0;
                    self.userInteractionEnabled = NO;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self removeFromSuperview];
                    });
                    break;
                }
            }
        }
    }
}

%end


// ============================================================================
// 4. 劫持配置字典与 NSUserDefaults：强制下发 ignoreSplashAd = YES & 超时 = 0
// 报告 5.5 & 5.7 节指出：开屏行为受 ignoreSplashAd、splash_timeout、splashReqTimeout 驱动
// ============================================================================
%hook NSDictionary

- (id)objectForKey:(id)aKey {
    if ([aKey isKindOfClass:[NSString class]]) {
        NSString *key = (NSString *)aKey;
        // 强制开启“全局忽略开屏”与“关闭预加载”
        if ([key isEqualToString:@"ignoreSplashAd"] ||
            [key isEqualToString:@"splash_disable_preload"]) {
            return @YES;
        }
        // 将所有开屏请求超时、展示超时、每日展示上限全部归零！
        if ([key isEqualToString:@"splash_timeout"] ||
            [key isEqualToString:@"splashReqTimeout"] ||
            [key isEqualToString:@"showFrequencyPerday"] ||
            [key isEqualToString:@"show_frequency_perday"] ||
            [key isEqualToString:@"dailyDisplayLimit"] ||
            [key isEqualToString:@"imp_freq_by_day"] ||
            [key isEqualToString:@"imp_freq_by_hour"] ||
            [key isEqualToString:@"ad_open"]) {
            return @0;
        }
    }
    return %orig;
}

- (id)valueForKey:(NSString *)key {
    if ([key isEqualToString:@"ignoreSplashAd"] || [key isEqualToString:@"splash_disable_preload"]) {
        return @YES;
    }
    if ([key isEqualToString:@"splash_timeout"] || [key isEqualToString:@"splashReqTimeout"] || [key isEqualToString:@"dailyDisplayLimit"]) {
        return @0;
    }
    return %orig;
}

%end

%hook NSUserDefaults

- (NSInteger)integerForKey:(NSString *)defaultName {
    // 报告 5.5 节：让本地记录的当日已展示开屏次数永远为 9999，直接触发日频控上限跳过开屏！
    if (defaultName && ([defaultName isEqualToString:@"TOBID_SPLASH_COUNT"] || [defaultName containsString:@"SPLASH_COUNT"])) {
        return 9999;
    }
    return %orig;
}

%end

// 拦截 Swift / ObjC 类的初始化，只要是 AdManager / LaunchUtil / AdSplash*，立刻修改其内部状态变量
%hook NSObject

- (instancetype)init {
    id instance = %orig;
    if (instance) {
        NSString *clsName = NSStringFromClass([instance class]);
        if ([clsName hasSuffix:@"AdManager"] ||
            [clsName hasSuffix:@"LaunchUtil"] ||
            [clsName containsString:@"AdSplash"] ||
            [clsName containsString:@"SplashModel"]) {
            nukeSplashIvars(instance);
        }
    }
    return instance;
}

%end


// ============================================================================
// 5. 禁用摇一摇与扭一扭广告传感器 (复刻报告 3.2 & 5.6 节 XCNoShake 能力)
// ============================================================================
%hook CMMotionManager

- (void)startAccelerometerUpdates {
    // 拒绝启动加速度计，废除摇一摇广告
}

- (void)startAccelerometerUpdatesToQueue:(NSOperationQueue *)queue withHandler:(CMAccelerometerHandler)handler {
    // 拒绝回调
}

- (void)startGyroUpdates {
    // 拒绝启动陀螺仪，废除扭一扭广告
}

- (void)startGyroUpdatesToQueue:(NSOperationQueue *)queue withHandler:(CMGyroHandler)handler {
    // 拒绝回调
}

- (void)startDeviceMotionUpdates {
    // 拒绝启动设备姿态传感器
}

- (void)startDeviceMotionUpdatesToQueue:(NSOperationQueue *)queue withHandler:(CMDeviceMotionHandler)handler {
    // 拒绝回调
}

%end


// ============================================================================
// 6. 插件入口：注册底层拦截协议
// ============================================================================
%ctor {
    @autoreleasepool {
        [NSURLProtocol registerClass:[XCFastAdBlockProtocol class]];
        NSLog(@">>> [XiaoCanAdBlock Pro] 已挂载 NSURLProtocol + LaunchView 强杀 + 三通道开屏熔断 + 禁摇一摇！");
    }
}
