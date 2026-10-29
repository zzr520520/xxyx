#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// =========================================================================
// 1. 拦截视图挂载：让开屏和闪屏视图直接不可见且不挡触控（绝不闪退）
// =========================================================================
%hook UIView

- (void)layoutSubviews {
    %orig;
    NSString *clsName = NSStringFromClass([self class]);
    if ([clsName localizedCaseInsensitiveContainsString:@"LaunchView"] ||
        [clsName localizedCaseInsensitiveContainsString:@"LaunchUtil"] ||
        [clsName localizedCaseInsensitiveContainsString:@"AdSplash"] ||
        [clsName localizedCaseInsensitiveContainsString:@"Splash"] ||
        [clsName localizedCaseInsensitiveContainsString:@"TobidAdContainer"]) {
        self.alpha = 0.0;
        self.hidden = YES;
        self.userInteractionEnabled = NO;
    }
}

%end


// =========================================================================
// 2. 拦截独立广告 Window（adWindow），强制其无法弹出
// =========================================================================
%hook UIWindow

- (void)makeKeyAndVisible {
    NSString *winCls = NSStringFromClass([self class]);
    NSString *rootVCCls = self.rootViewController ? NSStringFromClass([self.rootViewController class]) : @"";

    if ([winCls localizedCaseInsensitiveContainsString:@"Ad"] ||
        [winCls localizedCaseInsensitiveContainsString:@"Splash"] ||
        [rootVCCls localizedCaseInsensitiveContainsString:@"Splash"] ||
        [rootVCCls localizedCaseInsensitiveContainsString:@"Ad"]) {
        self.hidden = YES;
        self.alpha = 0.0;
        self.windowLevel = -1000.0;
        return;
    }
    %orig;
}

%end


// =========================================================================
// 3. 安全短路开屏管理器与三通道核心加载方法（防止任何线程死锁）
// =========================================================================
static void fastDismissSplash(id obj) {
    @try {
        SEL selectors[] = {
            @selector(splashAdDidClose:),
            @selector(splashAdClosed:),
            @selector(splashAdFailToPresent:withError:),
            @selector(dismiss),
            @selector(close)
        };
        for (int i = 0; i < 5; i++) {
            if ([obj respondsToSelector:selectors[i]]) {
                ((void (*)(id, SEL))objc_msgSend)(obj, selectors[i]);
                break;
            }
        }
    } @catch (NSException *e) {}
}

%hook AdSplashWM
- (void)loadAd {
    fastDismissSplash(self);
}
- (void)loadAdAndShow {
    fastDismissSplash(self);
}
%end

%hook AdSplashBU
- (void)loadAd {
    fastDismissSplash(self);
}
- (void)loadAdData {
    fastDismissSplash(self);
}
%end

%hook AdSplashMS
- (void)loadAd {
    fastDismissSplash(self);
}
%end


// =========================================================================
// 4. 全局配置键劫持：将超时归零，频控拉满
// =========================================================================
%hook NSDictionary

- (id)objectForKey:(id)aKey {
    if ([aKey isKindOfClass:[NSString class]]) {
        NSString *key = (NSString *)aKey;
        if ([key isEqualToString:@"ignoreSplashAd"] || [key isEqualToString:@"splash_disable_preload"]) {
            return @(YES);
        }
        if ([key isEqualToString:@"splash_timeout"] || [key isEqualToString:@"splashReqTimeout"]) {
            return @(0);
        }
    }
    return %orig;
}

%end

%ctor {
    // 纯净初始化，彻底移除了危险的 NSURLProtocol 协议栈，保障看门狗不超时
}
