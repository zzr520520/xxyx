#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>

// =========================================================================
// 1. 安全隐藏开屏视图（不触发 removeFromSuperview，避免 SnapKit 断言闪退）
// =========================================================================
%hook UIView

- (void)didAddSubview:(UIView *)subview {
    %orig;
    if (subview) {
        NSString *cls = NSStringFromClass([subview class]);
        // 匹配开屏、闪屏相关视图，只做透明与隐藏，保持视图层级关系以防 SnapKit 崩溃
        if ([cls localizedCaseInsensitiveContainsString:@"Splash"] ||
            [cls localizedCaseInsensitiveContainsString:@"Launch"] ||
            [cls localizedCaseInsensitiveContainsString:@"AdView"] ||
            [cls localizedCaseInsensitiveContainsString:@"Advert"]) {
            subview.hidden = YES;
            subview.alpha = 0.0;
            subview.userInteractionEnabled = NO;
        }
    }
}

%end

// =========================================================================
// 2. 斩断主窗口开屏逻辑，秒进 TabBar / 主界面
// =========================================================================
%hook UIWindow

- (void)setRootViewController:(UIViewController *)newRootVC {
    NSString *vcCls = NSStringFromClass([newRootVC class]);

    // 如果设置的根控制器是开屏/广告类控制器，直接绕过或加速
    if ([vcCls localizedCaseInsensitiveContainsString:@"Splash"] ||
        [vcCls localizedCaseInsensitiveContainsString:@"Launch"] ||
        [vcCls localizedCaseInsensitiveContainsString:@"Ad"]) {

        %orig;

        // 尝试主动调用其内部常见跳转方法
        dispatch_async(dispatch_get_main_queue(), ^{
            SEL selectors[] = {
                @selector(dismiss),
                @selector(skipAd),
                @selector(closeAd),
                @selector(goHome),
                @selector(enterMain),
                @selector(finishSplash)
            };
            for (int i = 0; i < sizeof(selectors) / sizeof(SEL); i++) {
                if ([newRootVC respondsToSelector:selectors[i]]) {
                    ((void (*)(id, SEL))objc_msgSend)(newRootVC, selectors[i]);
                    break;
                }
            }
        });
        return;
    }
    %orig;
}

- (void)makeKeyAndVisible {
    %orig;

    // 隐藏独立的广告 Window
    NSString *winCls = NSStringFromClass([self class]);
    if ([winCls localizedCaseInsensitiveContainsString:@"Splash"] ||
        [winCls localizedCaseInsensitiveContainsString:@"Ad"]) {
        self.hidden = YES;
        self.alpha = 0.0;
        [self resignKeyWindow];
    }
}

%end

// =========================================================================
// 3. 极速跳过广告管理器与倒计时 (0 秒关闭)
// =========================================================================
%hook NSTimer

+ (NSTimer *)scheduledTimerWithTimeInterval:(NSTimeInterval)ti target:(id)aTarget selector:(SEL)aSelector userInfo:(id)userInfo repeats:(BOOL)yesOrNo {
    NSString *selStr = NSStringFromSelector(aSelector);
    if ([selStr localizedCaseInsensitiveContainsString:@"countdown"] ||
        [selStr localizedCaseInsensitiveContainsString:@"splash"] ||
        [selStr localizedCaseInsensitiveContainsString:@"dismiss"] ||
        [selStr localizedCaseInsensitiveContainsString:@"skip"]) {
        ti = 0.001; // 倒计时瞬间结束
    }
    return %orig(ti, aTarget, aSelector, userInfo, yesOrNo);
}

%end

// =========================================================================
// 4. 彻底切断第三方广告聚合入口（防止后台跑 5 秒超时）
// =========================================================================
%hook AdbidSplashAd
- (void)loadAd {}
- (void)loadAdAndShowInWindow:(id)arg1 {}
- (void)showAd:(id)arg1 {}
- (void)showInWindow:(id)arg1 withBottomView:(id)arg2 {}
- (BOOL)isAdValid { return NO; }
%end

%hook BUSplashAdView
- (void)loadAdData {}
%end

%hook GDTSplashAd
- (void)loadAdAndShowInWindow:(id)window {}
%end

%hook WindMillSplashAd
- (void)loadAdAndShow {}
- (void)loadAd {}
%end

// 构造函数不执行任何 UI 弹窗，完全静默载入
%ctor {
}
