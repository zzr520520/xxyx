#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

// ==========================================
// 1. 开屏秒进：Hook 自有业务层的开屏控制器
// ==========================================
%hook YXSplashTakuAdVC

- (void)viewDidLoad {
    %orig;
    NSLog(@">>> [Dylib] 拦截到 TopOn 开屏控制器，强制触发跳过/进入主页");
    // 延迟极短时间后，模拟点击跳过或直接调用关闭方法进入主程序
    [self performSelector:@selector(skipAction) withObject:nil afterDelay:0.2];
}

%end

%hook YXSplashAdVC

- (void)viewDidLoad {
    %orig;
    NSLog(@">>> [Dylib] 拦截到 WindMill 开屏控制器，强制触发跳过/进入主页");
    // 依据实际业务类可能的方法调整，通常可发送通知或直接dismiss
    [self dismissViewControllerAnimated:NO completion:nil];
}

%end


// ==========================================
// 2. 网络请求黑洞：拦截广告请求域名
// ==========================================
%hook NSURL

// 拦截 [[NSURL alloc] initWithString:]，将广告域名重定向到一个无效地址或直接返回 nil
- (instancetype)initWithString:(NSString *)URLString {
    if (URLString) {
        // 匹配报告和抓包中常见的广告、统计、配置下发域名
        if ([URLString containsString:@"sdk-api.adn-plus.com.cn"] ||
            [URLString containsString:@"tm.sigmob.cn"] ||
            [URLString containsString:@"xadsmartget.adgain.cn"] ||
            [URLString containsString:@"ujoy.anythinktech.com"] ||
            [URLString containsString:@"sdk.beizi.biz"]) {

            // 打印拦截日志
            // NSLog(@">>> [Dylib] 成功屏蔽广告/统计请求: %@", URLString);

            // 重定向到一个本地无效地址，使请求直接失败
            URLString = @"http://127.0.0.1/ad_blocked_empty";
        }
    }
    return %orig(URLString);
}

%end


// ==========================================
// 3. UI 视图去广告：隐藏原生底部/活动页广告位
// ==========================================
%hook YXHomeRootBottomAdView

- (void)layoutSubviews {
    %orig;
    // 将首页底部广告 View 尺寸清零并隐藏
    // YXHomeRootBottomAdView 仅被 Logos 前向声明，需强转为 UIView 才能访问 frame/hidden
    [(UIView *)self setFrame:CGRectZero];
    [(UIView *)self setHidden:YES];
}

%end
