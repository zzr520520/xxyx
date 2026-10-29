#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// 声明聚合/联盟开屏的 delegate 回调选择器，仅供编译器解析（无运行时实现，不改变原逻辑）
@interface NSObject (XCAdSplashCallbacks)
- (void)splashAdFailToPresent:(id)ad withError:(NSError *)error;
- (void)splashAdDidClose:(id)ad;
- (void)splashAdClosed:(id)ad;
@end

// =========================================================================
// 1. 业务广告服务层：直接伪造网关不开启开屏 (针对 MatchPlacement 接口)
// =========================================================================
%hook NSJSONSerialization

+ (id)JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)opt error:(NSError **)error {
    id obj = %orig;
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)obj;
        // 匹配广告点位下发接口
        if (dict[@"data"] && [dict[@"data"] isKindOfClass:[NSDictionary class]]) {
            NSDictionary *dataDict = dict[@"data"];
            if (dataDict[@"ad_open"] != nil) {
                NSMutableDictionary *mutableDict = [dict mutableCopy];
                NSMutableDictionary *mutableData = [dataDict mutableCopy];
                mutableData[@"ad_open"] = @(0); // 强制声明无广告
                mutableData[@"ad_source"] = @[];
                mutableData[@"ios_slot_id"] = @"";
                mutableDict[@"data"] = mutableData;
                return mutableDict;
            }
        }
    }
    return obj;
}

%end


// =========================================================================
// 2. 逆向报告 4.4 聚合层拦截：欺骗 Adbid 开屏管理器瞬间完成
// =========================================================================

// Hook 自建聚合核心开屏类
%hook AdbidSplashAd

- (void)loadAd {
    // 主动触发加载失败代理，让外层业务直接跳过等待
    id delegate = [self valueForKey:@"delegate"];
    if (delegate && [delegate respondsToSelector:@selector(splashAdFailToPresent:withError:)]) {
        [delegate splashAdFailToPresent:self withError:nil];
    }
}

- (void)loadAdAndShowInWindow:(id)window {
    id delegate = [self valueForKey:@"delegate"];
    if (delegate && [delegate respondsToSelector:@selector(splashAdDidClose:)]) {
        [delegate splashAdDidClose:self];
    }
}

- (void)showInWindow:(id)window withBottomView:(id)bottomView {
    id delegate = [self valueForKey:@"delegate"];
    if (delegate && [delegate respondsToSelector:@selector(splashAdDidClose:)]) {
        [delegate splashAdDidClose:self];
    }
}

- (BOOL)isAdValid {
    return NO;
}

%end


// =========================================================================
// 3. 抹掉穿山甲、优量汇、Sigmob、快手等主流联盟的原生开屏加载
// =========================================================================

// 穿山甲开屏
%hook BUSplashAdView
- (void)loadAdData {
    id delegate = [self valueForKey:@"delegate"];
    if (delegate && [delegate respondsToSelector:@selector(splashAdDidClose:)]) {
        [delegate splashAdDidClose:(id)self];
    }
}
%end

// 优量汇开屏
%hook GDTSplashAd
- (void)loadAdAndShowInWindow:(id)window {
    id delegate = [self valueForKey:@"delegate"];
    if (delegate && [delegate respondsToSelector:@selector(splashAdClosed:)]) {
        [delegate splashAdClosed:self];
    }
}
%end

// Sigmob 开屏
%hook WindMillSplashAd
- (void)loadAdAndShow {
    id delegate = [self valueForKey:@"delegate"];
    if (delegate && [delegate respondsToSelector:@selector(splashAdClosed:)]) {
        [delegate splashAdClosed:(id)self];
    }
}
%end

// 快手开屏
%hook KSAdSplashViewController
- (void)viewDidLoad {
    %orig;
    // 快手控制器直接秒关
    [self dismissViewControllerAnimated:NO completion:nil];
}
%end


// =========================================================================
// 4. 解决 8 秒卡顿的元凶：给网络请求加速降级，严禁让其重试堵塞
// =========================================================================

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    NSString *url = request.URL.absoluteString;

    // 只放行业务接口，对第三方竞价、配置、上报做伪造空包快速响应（返回200而不是报错，防止SDK无限卡死重试）
    if ([url containsString:@"pangolin-sdk"] ||
        [url containsString:@"sigmob.cn"] ||
        [url containsString:@"mentamob.com"] ||
        [url containsString:@"adbiding.com"] ||
        [url containsString:@"1rtb.net"] ||
        [url containsString:@"hubcloud.com.cn"] ||
        [url containsString:@"beizi.biz"] ||
        [url containsString:@"fancyapi.com"] ||
        [url containsString:@"gdt.qq.com"]) {

        if (completionHandler) {
            // 构造假 200 空响应，SDK 认为服务端无广告填充，立刻退出，不再卡 8 秒！
            NSHTTPURLResponse *fakeResp = [[NSHTTPURLResponse alloc] initWithURL:request.URL
                                                                      statusCode:200
                                                                     HTTPVersion:@"HTTP/1.1"
                                                                    headerFields:@{@"Content-Type": @"application/json"}];
            NSData *emptyData = [@"{\"code\":20001,\"data\":\"\",\"msg\":\"no ad\"}" dataUsingEncoding:NSUTF8StringEncoding];
            dispatch_async(dispatch_get_main_queue(), ^{
                completionHandler(emptyData, fakeResp, nil);
            });
        }

        NSURLSessionDataTask *dummy = %orig(request, nil);
        [dummy cancel];
        return dummy;
    }

    return %orig;
}

%end

// 静默初始化
%ctor {
}
