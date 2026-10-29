#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// =========================================================================
// 1. 彻底干掉首屏兜底：LaunchUtil / launchView (截图里的“大额红包”)
// =========================================================================
%hook LaunchUtil

// 拦截获取 launchView，直接返回空或者让其隐藏
- (id)launchView {
    UIView *view = %orig;
    if (view) {
        view.hidden = YES;
        view.alpha = 0.0;
    }
    return view;
}

// 如果内部有展示闪屏的方法，直接短路
- (void)showLaunchView {
    // 空实现，不展示原生闪屏
}

- (void)dismissLaunchView {
    %orig;
}

%end


// =========================================================================
// 2. 核心调度层：强行开启“忽略开屏”开关 (AdManager / SplashModel)
// =========================================================================
%hook AdManager

// 报告 5.1 & 5.7：通过 ignoreSplashAd 彻底关停开屏流程
- (BOOL)ignoreSplashAd {
    return YES;
}

// 如果作为属性存在
- (id)splashModel {
    id model = %orig;
    if (model) {
        @try {
            [model setValue:@(YES) forKey:@"ignoreSplashAd"];
            [model setValue:@(0.01) forKey:@"splash_timeout"];
            [model setValue:@(0.01) forKey:@"splashReqTimeout"];
        } @catch (NSException *e) {}
    }
    return model;
}

// 拦截准备与加载开屏方法，直接不做任何加载
- (void)loadSplashAd {
    // 直接返回，不发起三通道拉取
}

- (void)showSplashAd {
    // 直接返回
}

%end


// =========================================================================
// 3. 报告 5.1：精准打击开屏三通道实现类 (AdSplashWM, AdSplashBU, AdSplashMS)
// =========================================================================

// 通道一：ToBid (WindMill)
%hook AdSplashWM

- (void)loadAd {
    // 不拉取广告
}

- (void)showInWindow:(id)arg1 {
    // 报告 5.1：隐藏持有的 adWindow 并立刻结束
    UIWindow *win = [self valueForKey:@"adWindow"];
    if (win) {
        win.hidden = YES;
    }
}

%end

// 通道二：穿山甲 BU
%hook AdSplashBU

- (void)loadAd {
}

- (void)showInWindow:(id)arg1 {
}

%end

// 通道三：美数 MS
%hook AdSplashMS

- (void)loadAd {
}

- (void)showInWindow:(id)arg1 {
    UIWindow *win = [self valueForKey:@"adWindow"];
    if (win) {
        win.hidden = YES;
    }
}

%end


// =========================================================================
// 4. 报告 5.4：兜底关闭管理器 (AdForceCloseManager)
// =========================================================================
%hook AdForceCloseManager

// 如果触发了强制兜底，直接执行关闭回调
- (void)showForceCloseBtnOnView:(id)arg1 {
    void (^closeBlock)(void) = [self valueForKey:@"closeBack"];
    if (closeBlock) {
        closeBlock();
    }
}

%end


// =========================================================================
// 5. 独立广告窗口拦截 (防止 AdSplashMS / WM 的 adWindow 盖住主界面)
// =========================================================================
%hook UIWindow

- (void)makeKeyAndVisible {
    // 避免非主窗口（开屏独立窗口）抢占焦点
    if (self != [UIApplication sharedApplication].delegate.window) {
        NSString *cls = NSStringFromClass([self class]);
        if ([cls localizedCaseInsensitiveContainsString:@"Splash"] ||
            [cls localizedCaseInsensitiveContainsString:@"AdWindow"]) {
            self.hidden = YES;
            return;
        }
    }
    %orig;
}

%end

%ctor {
    // 纯静默载入，零弹窗，零网络死锁风险
}
