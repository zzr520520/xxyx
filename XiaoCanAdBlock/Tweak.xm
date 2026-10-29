#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// 1. Hook 核心聚合 SDK: AdbidSplashAd
%hook AdbidSplashAd

// 阻止开屏加载，防止后台发起耗时网络请求与竞价
- (void)loadAd {
    // 直接不执行原逻辑，或模拟失败以跳过等待
    NSLog(@"[NoSplash] AdbidSplashAd loadAd blocked.");
}

// 阻止广告展示到主 Window
- (void)showAd:(id)arg1 {
    NSLog(@"[NoSplash] AdbidSplashAd showAd blocked.");
}

- (void)showInWindow:(UIWindow *)window withBottomView:(UIView *)bottomView {
    NSLog(@"[NoSplash] AdbidSplashAd showInWindow blocked.");
    // 如果业务层依赖 delegate 通知关闭，可主动触发 dismiss/finish 相关的 delegate 方法
}

%end

// 2. 兜底 Hook：穿山甲 CSJ 开屏视图
%hook BUSplashAdView
- (id)initWithSlot:(id)arg1 frame:(CGRect)arg2 {
    NSLog(@"[NoSplash] BUSplashAdView blocked.");
    return nil;
}
%end

// 3. 兜底 Hook：优量汇 GDTSplashAd
%hook GDTSplashAd
- (void)loadAdAndShowInWindow:(UIWindow *)window {
    NSLog(@"[NoSplash] GDTSplashAd blocked.");
}
- (void)showAdInWindow:(UIWindow *)window withBottomView:(UIView *)bottomView {
    NSLog(@"[NoSplash] GDTSplashAd show blocked.");
}
%end

// 4. 处理 App 自身的开屏 ViewController 或倒计时 Window
// 小蚕惠生活在主入口会有广告承载控制器，如果发现界面依然存在倒计时容器：
%hook XCFoundation // 或对应的业务开屏容器类
// 如果找到承载广告的 VC，重写其 viewDidLoad 或 viewWillAppear，让其直接 dismiss 或切换到 TabBarVC
%end
