#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

// UIWindow 私有方法声明（供 Logos 解析 %orig）
@interface UIWindow (XiaoCanPrivate)
- (BOOL)_isConstrainedByScreenBounds;
@end

// ============================================================================
// 1. 强力劫持网关广告配置响应：将所有开屏广告开关全部置零 (ad_open: 0)
// ============================================================================
%hook NSDictionary

- (id)objectForKey:(id)aKey {
    id val = %orig;
    // 拦截小蚕网关返回的广告配置字段，强制关闭开屏
    if ([aKey isKindOfClass:[NSString class]]) {
        NSString *keyStr = (NSString *)aKey;
        if ([keyStr isEqualToString:@"ad_open"] || [keyStr isEqualToString:@"is_appopen_lb"]) {
            return @0; // 强制设为关闭
        }
    }
    return val;
}

%end


// ============================================================================
// 2. 暴力秒进：全方位拦截并销毁所有开屏控制器与启动动画视图
// ============================================================================
%hook UIViewController

- (void)viewDidLoad {
    %orig;
    NSString *className = NSStringFromClass([self class]);
    if (!className) return;

    // 过滤并精准打击所有包含 Splash、Launch、AdOpen 或广告相关的控制器
    if ([className containsString:@"Splash"] ||
        [className containsString:@"splash"] ||
        [className containsString:@"AppOpen"] ||
        [className containsString:@"AdOpen"] ||
        [className containsString:@"LaunchAd"]) {

        NSLog(@">>> [XiaoCanInstant] 捕获到开屏/广告控制器: %@", className);

        // 瞬间清空视图并移除
        self.view.hidden = YES;
        self.view.alpha = 0.0;

        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.presentingViewController) {
                [self dismissViewControllerAnimated:NO completion:nil];
            }
            [self.view removeFromSuperview];
            [self removeFromParentViewController];
        });
    }
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    NSString *className = NSStringFromClass([self class]);
    if (!className) return;

    if ([className containsString:@"Splash"] || [className containsString:@"splash"] || [className containsString:@"AppOpen"]) {
        // 再次尝试通过常见选择器强行关闭
        NSArray *actions = @[@"skipAction", @"closeAction", @"dismissAction", @"splashDidClose"];
        for (NSString *actionStr in actions) {
            SEL sel = NSSelectorFromString(actionStr);
            if ([self respondsToSelector:sel]) {
                ((void (*)(id, SEL))objc_msgSend)(self, sel);
            }
        }
    }
}

%end


// ============================================================================
// 3. 根视图与广告窗口拦截：防止本地静态开屏图残留
// ============================================================================
%hook UIWindow

- (BOOL)_isConstrainedByScreenBounds {
    return %orig;
}

- (void)makeKeyAndVisible {
    %orig;
    // 检查是否是广告独立悬浮 Window，如果是则直接隐藏
    NSString *windowClassName = NSStringFromClass([self class]);
    if ([windowClassName containsString:@"Ad"] || [windowClassName containsString:@"Splash"]) {
        self.hidden = YES;
    }
}

%end
