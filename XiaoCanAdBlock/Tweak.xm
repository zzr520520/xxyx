#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// 辅助打印日志宏
#define XCLog(fmt, ...) NSLog((@"[NoSplashHook] " fmt), ##__VA_ARGS__)

// =========================================================================
// 策略 1：拦截通用广告开屏管理器与代理回调（防止业务逻辑被挂起）
// =========================================================================

// 1. Hook 聚合层开屏管理类 AdbidSplashAd
%hook AdbidSplashAd

- (void)loadAd {
    XCLog(@"Intercepted AdbidSplashAd loadAd");
    // 不执行原网络请求，尝试通知代理已失败或关闭，驱动业务进入主流程
    id delegate = [self valueForKey:@"delegate"];
    if (delegate) {
        if ([delegate respondsToSelector:@selector(splashAdFailToPresent:error:)]) {
            [delegate performSelector:@selector(splashAdFailToPresent:error:) withObject:self withObject:nil];
        } else if ([delegate respondsToSelector:@selector(splashAdDidClose:)]) {
            [delegate performSelector:@selector(splashAdDidClose:) withObject:self];
        }
    }
}

- (void)showAd:(id)arg1 {
    XCLog(@"Intercepted AdbidSplashAd showAd:");
}

- (void)showInWindow:(UIWindow *)window withBottomView:(UIView *)bottomView {
    XCLog(@"Intercepted AdbidSplashAd showInWindow:withBottomView:");
    // 如果页面正在等待代理关闭回调，主动唤起关闭
    id delegate = [self valueForKey:@"delegate"];
    if (delegate && [delegate respondsToSelector:@selector(splashAdDidClose:)]) {
        [delegate performSelector:@selector(splashAdDidClose:) withObject:self];
    }
}

%end

// 2. Hook 穿山甲开屏核心类
%hook BUSplashAdView
- (void)loadAdData {
    XCLog(@"Intercepted BUSplashAdView loadAdData");
    id delegate = [self valueForKey:@"delegate"];
    if (delegate && [delegate respondsToSelector:@selector(splashAdDidClose:)]) {
        [delegate performSelector:@selector(splashAdDidClose:) withObject:self];
    }
}
%end

// 3. Hook 优量汇开屏核心类
%hook GDTSplashAd
- (void)loadAdAndShowInWindow:(id)window {
    XCLog(@"Intercepted GDTSplashAd loadAdAndShowInWindow:");
    id delegate = [self valueForKey:@"delegate"];
    if (delegate && [delegate respondsToSelector:@selector(splashAdClosed:)]) {
        [delegate performSelector:@selector(splashAdClosed:) withObject:self];
    }
}
%end


// =========================================================================
// 策略 2：UI 容器层兜底 —— 强行跳过开屏 ViewController / 自动点击跳过
// =========================================================================

// 监听所有 Controller 的展示，若为开屏/广告类控制器，直接 dismiss 或切换
%hook UIViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;

    NSString *className = NSStringFromClass([self class]);

    // 过滤命中开屏、广告、倒计时的控制器类名
    if ([className localizedCaseInsensitiveContainsString:@"Splash"] ||
        [className localizedCaseInsensitiveContainsString:@"LaunchAd"] ||
        [className localizedCaseInsensitiveContainsString:@"Advertisement"]) {

        XCLog(@"Detected Splash VC: %@, dismissing immediately...", className);

        // 尝试自动点击跳过按钮
        [self dismissViewControllerAnimated:NO completion:nil];

        // 如果当前是 RootViewController，尝试调用子控制器或通知导航切换
        if (self.view.window && self.view.window.rootViewController == self) {
            // 查找业务内可能保存的主界面或导航
            [self.view setHidden:YES];
            [self.view removeFromSuperview];
        }
    }
}

// 自动寻找并触发屏幕上的“跳过”/倒计时按钮
- (void)viewDidAppear:(BOOL)animated {
    %orig;

    NSString *className = NSStringFromClass([self class]);
    if ([className localizedCaseInsensitiveContainsString:@"Splash"] ||
        [className localizedCaseInsensitiveContainsString:@"Launch"]) {

        // 遍历当前视图层级，找到所有可能包含“跳过”或倒计时的按钮并触发点击
        for (UIView *subview in self.view.subviews) {
            if ([subview isKindOfClass:[UIButton class]]) {
                UIButton *btn = (UIButton *)subview;
                NSString *title = [btn titleForState:UIControlStateNormal];
                if ([title containsString:@"跳过"] || [title containsString:@"Skip"] || btn.tag == 1001) {
                    XCLog(@"Found skip button, triggering click event!");
                    [btn sendActionsForControlEvents:UIControlEventTouchUpInside];
                    break;
                }
            }
        }
    }
}

%end


// =========================================================================
// 策略 3：拦截多 Window 广告弹窗遮罩（秒删广告 Window）
// =========================================================================

%hook UIWindow

- (void)becomeKeyWindow {
    %orig;

    NSString *className = NSStringFromClass([self class]);
    // 很多广告 SDK（如穿山甲、Sigmob、乐盟）会独立新建一个覆盖在最上层的 UIWindow
    if ([className localizedCaseInsensitiveContainsString:@"Splash"] ||
        [className localizedCaseInsensitiveContainsString:@"AdWindow"]) {

        XCLog(@"Detected Ad Window: %@, hiding it.", className);
        self.hidden = YES;
        [self resignKeyWindow];
    }
}

%end


// =========================================================================
// 构造函数初始化提示
// =========================================================================
%ctor {
    @autoreleasepool {
        XCLog(@"=== XiaoCan NoSplash Dylib Loaded Successfully ===");
    }
}
