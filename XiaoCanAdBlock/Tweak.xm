#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// =========================================================================
// 1. 暴力干掉开屏视图与业务兜底图（见图：大额红包在小蚕）
// =========================================================================
%hook UIView

- (void)didMoveToSuperview {
    %orig;
    if (self.superview) {
        NSString *cls = NSStringFromClass([self class]);
        // 匹配所有带 Splash、Launch、Ad 开头的原生/Flutter容器视图
        if ([cls localizedCaseInsensitiveContainsString:@"Splash"] ||
            [cls localizedCaseInsensitiveContainsString:@"LaunchView"] ||
            [cls localizedCaseInsensitiveContainsString:@"XCAdSplash"] ||
            [cls localizedCaseInsensitiveContainsString:@"XCSplash"]) {

            self.hidden = YES;
            self.alpha = 0.0;
            [self removeFromSuperview];
        }
    }
}

%end

// =========================================================================
// 2. 强行跳过开屏控制器生命周期 (若有单独的 Controller)
// =========================================================================
%hook UIViewController

- (void)viewWillAppear:(BOOL)animated {
    NSString *cls = NSStringFromClass([self class]);
    if ([cls localizedCaseInsensitiveContainsString:@"Splash"] ||
        [cls localizedCaseInsensitiveContainsString:@"Launch"] ||
        [cls localizedCaseInsensitiveContainsString:@"Advertisement"]) {

        // 瞬间隐藏并关闭该控制器
        self.view.hidden = YES;
        [self dismissViewControllerAnimated:NO completion:nil];
        return;
    }
    %orig;
}

%end

// =========================================================================
// 3. 熔断倒计时 NSTimer / GCD 延时（解决等 3~5 秒的罪魁祸首）
// =========================================================================
%hook NSTimer

+ (NSTimer *)scheduledTimerWithTimeInterval:(NSTimeInterval)ti target:(id)aTarget selector:(SEL)aSelector userInfo:(id)userInfo repeats:(BOOL)yesOrNo {
    NSString *selStr = NSStringFromSelector(aSelector);
    // 拦截跳过倒计时、闪屏超时定时器
    if ([selStr localizedCaseInsensitiveContainsString:@"countdown"] ||
        [selStr localizedCaseInsensitiveContainsString:@"splash"] ||
        [selStr localizedCaseInsensitiveContainsString:@"timeout"] ||
        [selStr localizedCaseInsensitiveContainsString:@"dismiss"]) {
        // 将倒计时直接缩至 0 秒，促使回调立刻触发跳过
        ti = 0.01;
    }
    return %orig(ti, aTarget, aSelector, userInfo, yesOrNo);
}

%end

// =========================================================================
// 4. 业务层：彻底关闭业务广告下发 (ad_open = 0)
// =========================================================================
%hook NSJSONSerialization

+ (id)JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)opt error:(NSError **)error {
    id obj = %orig;
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)obj;
        if (dict[@"data"] && [dict[@"data"] isKindOfClass:[NSDictionary class]]) {
            NSDictionary *dataDict = dict[@"data"];
            if (dataDict[@"ad_open"] != nil) {
                NSMutableDictionary *mutableDict = [dict mutableCopy];
                NSMutableDictionary *mutableData = [dataDict mutableCopy];
                mutableData[@"ad_open"] = @(0);
                mutableDict[@"data"] = mutableData;
                return mutableDict;
            }
        }
    }
    return obj;
}

%end

// =========================================================================
// 5. 阻止各大 SDK 冗余网络阻塞
// =========================================================================
%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
    NSString *url = request.URL.absoluteString;
    if ([url containsString:@"pangolin-sdk"] ||
        [url containsString:@"sigmob.cn"] ||
        [url containsString:@"mentamob.com"] ||
        [url containsString:@"adbiding.com"] ||
        [url containsString:@"1rtb.net"] ||
        [url containsString:@"hubcloud.com.cn"] ||
        [url containsString:@"gdt.qq.com"]) {

        if (completionHandler) {
            NSError *err = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotConnectToHost userInfo:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                completionHandler(nil, nil, err);
            });
        }
        NSURLSessionDataTask *task = %orig(request, nil);
        [task cancel];
        return task;
    }
    return %orig;
}

%end

// 构造函数不放任何弹窗阻塞，确保静默秒进
%ctor {
    // 静默加载
}
