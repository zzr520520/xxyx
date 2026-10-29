#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// =========================================================================
// 1. 业务层：篡改业务网关广告开关 (MatchPlacement -> ad_open: 0)
// =========================================================================
%hook NSJSONSerialization

+ (id)JSONObjectWithData:(NSData *)data options:(NSJSONReadingOptions)opt error:(NSError **)error {
    id obj = %orig;

    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)obj;
        // 匹配业务网关广告配置节点
        if (dict[@"data"] && [dict[@"data"] isKindOfClass:[NSDictionary class]]) {
            NSDictionary *dataDict = dict[@"data"];
            if (dataDict[@"ad_open"] != nil && [dataDict[@"ad_open"] intValue] == 1) {
                NSLog(@"[NoSplash] >>> 命中广告点位配置，强制篡改 ad_open = 0");
                NSMutableDictionary *mutableDict = [dict mutableCopy];
                NSMutableDictionary *mutableData = [dataDict mutableCopy];
                mutableData[@"ad_open"] = @(0); // 强行关闭开屏开关
                mutableDict[@"data"] = mutableData;
                return mutableDict;
            }
        }
    }

    return obj;
}

%end


// =========================================================================
// 2. 传输层：阻断所有导致超时的广告网络连接（直接报失败，0秒快速降级）
// =========================================================================
%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
    NSString *urlString = request.URL.absoluteString;

    // 匹配抓包中所有高延迟或触发超时的广告域名
    if ([urlString containsString:@"pangolin-sdk"] ||      // 穿山甲 Pangle
        [urlString containsString:@"sigmob.cn"] ||          // Sigmob / WindMill
        [urlString containsString:@"mentamob.com"] ||       // 盟推 Menta
        [urlString containsString:@"adbiding.com"] ||       // 乐盟聚合 Tobid
        [urlString containsString:@"1rtb.net"] ||           // 美数 MSAdSDK
        [urlString containsString:@"hubcloud.com.cn"] ||    // 欧克 OctCore
        [urlString containsString:@"beizi.biz"] ||          // 倍孜 BeiZi
        [urlString containsString:@"fancyapi.com"] ||       // Fancy RTB
        [urlString containsString:@"gdt.qq.com"]) {         // 优量汇 GDT

        NSLog(@"[NoSplash] >>> 快速熔断广告请求: %@", urlString);

        if (completionHandler) {
            // 立即抛出网络不可达错误，促使 SDK 瞬间退出，不再等待 5000ms 超时
            NSError *error = [NSError errorWithDomain:NSURLErrorDomain
                                                 code:NSURLErrorCannotConnectToHost
                                             userInfo:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                completionHandler(nil, nil, error);
            });
        }

        // 构造一个处于已完成状态的空任务，阻止实际发包
        NSURLSessionDataTask *dummyTask = %orig(request, nil);
        [dummyTask cancel];
        return dummyTask;
    }

    return %orig;
}

%end


// =========================================================================
// 3. 注入验证与启动初始化（若注入成功，进入 App 0.5 秒内必弹窗提示）
// =========================================================================
%ctor {
    @autoreleasepool {
        NSLog(@"[NoSplash] >>> Dylib 成功载入 Mach-O 二进制！");

        // 延迟 0.5 秒展示弹窗，用于肉眼确认插件是否成功运行
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIWindow *keyWindow = nil;
            if (@available(iOS 13.0, *)) {
                for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                    if (scene.activationState == UISceneActivationStateForegroundActive) {
                        for (UIWindow *w in scene.windows) {
                            if (w.isKeyWindow) {
                                keyWindow = w;
                                break;
                            }
                        }
                    }
                }
            }
            if (!keyWindow) {
                keyWindow = [UIApplication sharedApplication].delegate.window;
            }

            UIViewController *rootVC = keyWindow.rootViewController;
            if (rootVC) {
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"去开屏插件"
                                                                               message:@"Dylib 注入成功并已生效！"
                                                                        preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
                [rootVC presentViewController:alert animated:YES completion:nil];
            }
        });
    }
}
