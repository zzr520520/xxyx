#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// =========================================================================
// 1. 彻底摧毁报告中的聚合 SDK 工厂与开屏调度 (Adbid / XiaoCanAd)
// =========================================================================

// 阻断中介层工厂创建适配器（报告 4.4 明确指出的工厂类）
%hook AdbidSplashAdapterFactory
+ (id)createAdapterWithPlatform:(id)arg1 {
    return nil;
}
%end

// 阻断开屏类所有加载与展示（报告 4.4 对外接口族 AdbidSplashAd）
%hook AdbidSplashAd

- (id)init {
    return nil;
}

- (void)loadAd {
}

- (void)loadAdWithToken:(id)arg1 {
}

- (void)showAd:(id)arg1 {
}

- (void)showInWindow:(id)arg1 withBottomView:(id)arg2 {
}

- (BOOL)isAdValid {
    return NO;
}

%end

// 阻断应用级广告组件 XiaoCanAd (报告 3.2 pod_config.json 指出)
%hook XiaoCanAd
+ (id)sharedInstance {
    return nil;
}
- (void)loadSplashAd:(id)arg1 {
}
%end


// =========================================================================
// 2. 暴力移除第一层：业务本地的“大额红包在小蚕”占位图与遮罩视图
// =========================================================================

%hook UIView

- (void)addSubview:(UIView *)view {
    NSString *subCls = NSStringFromClass([view class]);

    // 拦截任何包含开屏、闪屏、启动遮罩特征的 View 挂载到主图层
    if ([subCls localizedCaseInsensitiveContainsString:@"Splash"] ||
        [subCls localizedCaseInsensitiveContainsString:@"Launch"] ||
        [subCls localizedCaseInsensitiveContainsString:@"AdView"] ||
        [subCls localizedCaseInsensitiveContainsString:@"Guide"] ||
        [subCls localizedCaseInsensitiveContainsString:@"Advert"]) {

        // 瞬间抹杀，不让它被添加到父图层
        view.hidden = YES;
        view.alpha = 0.0;
        return;
    }
    %orig;
}

%end


// =========================================================================
// 3. 根治“卡死等待”：让 App 的主 Window 瞬间暴露，清理广告 Window
// =========================================================================

%hook UIWindow

- (void)makeKeyAndVisible {
    %orig;

    // 检查当前 Window 上的所有子视图，如果盖着全屏大图，直接踢出
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        for (UIView *sub in self.subviews) {
            // 只要不是主交互根视图控制器的主 View，且占满全屏的，统统强行移除
            if (sub != self.rootViewController.view) {
                NSString *subName = NSStringFromClass([sub class]);
                if ([subName localizedCaseInsensitiveContainsString:@"Splash"] ||
                    [subName localizedCaseInsensitiveContainsString:@"Launch"] ||
                    [subName localizedCaseInsensitiveContainsString:@"Ad"] ||
                    CGRectEqualToRect(sub.frame, [UIScreen mainScreen].bounds)) {

                    sub.hidden = YES;
                    [sub removeFromSuperview];
                }
            }
        }
    });
}

// 阻止任何独立的广告 Window 成为 KeyWindow
- (void)becomeKeyWindow {
    NSString *winCls = NSStringFromClass([self class]);
    if ([winCls localizedCaseInsensitiveContainsString:@"Splash"] ||
        [winCls localizedCaseInsensitiveContainsString:@"AdWindow"]) {
        self.hidden = YES;
        [self resignKeyWindow];
        return;
    }
    %orig;
}

%end


// =========================================================================
// 4. 控制器层秒进：如果是开屏控制器，强行替换为 TabBar 或直接淡出
// =========================================================================

%hook UIViewController

- (void)viewDidLoad {
    %orig;
    NSString *vcName = NSStringFromClass([self class]);

    if ([vcName localizedCaseInsensitiveContainsString:@"Splash"] ||
        [vcName localizedCaseInsensitiveContainsString:@"Launch"] ||
        [vcName localizedCaseInsensitiveContainsString:@"Advertise"]) {

        // 该控制器一加载就立刻隐藏并强行关闭
        self.view.hidden = YES;
        [self dismissViewControllerAnimated:NO completion:nil];
    }
}

%end


// =========================================================================
// 5. 阻断网络请求发包与超时（0秒响应）
// =========================================================================

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    NSString *url = request.URL.absoluteString;

    // 匹配自建聚合(ads-bid.leadmoad.com) 及各大联盟
    if ([url containsString:@"leadmoad.com"] ||
        [url containsString:@"adbiding.com"] ||
        [url containsString:@"tobidad.cn"] ||
        [url containsString:@"pangolin-sdk"] ||
        [url containsString:@"sigmob.cn"] ||
        [url containsString:@"mentamob.com"] ||
        [url containsString:@"gdt.qq.com"]) {

        if (completionHandler) {
            NSError *err = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotConnectToHost userInfo:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                completionHandler(nil, nil, err);
            });
        }
        NSURLSessionDataTask *dummy = %orig(request, nil);
        [dummy cancel];
        return dummy;
    }
    return %orig;
}

%end
