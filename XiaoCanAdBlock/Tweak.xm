#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreMotion/CoreMotion.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <dlfcn.h>
#import <unistd.h>
#import <dispatch/dispatch.h>

static CFAbsoluteTime kAppLaunchTime = 0;

// 2.8.7 诊断用：启动期"阻塞原语"的调用次数与累计阻塞秒数（只统计，不改变行为）
static volatile int    gCntSem = 0, gCntGrp = 0, gCntSlp = 0;
static volatile double gBlkSem = 0, gBlkGrp = 0, gBlkSlp = 0;

// ============================================================================
// 2.8.3 找回"秒开"，同时不再动首页
// ----------------------------------------------------------------------------
// 分析报告结论：
//   * 开屏是"独立 UIWindow"（AdSplashMS/WM 各自持有 adWindow），不贴在 keyWindow 上；
//   * App 自带 LaunchUtil.launchView 兜底启动页（T0），这才是"不秒开"时你看到的画面；
//   * 参照实现 XCNoAdJump 只做网络拦截 + SDK swizzling + 禁传感器 + 外跳拦截。
// 2.8.2 用"精确类名"清图 → 首页正常，但启动页类名不带 Launch/Splash，所以又露出来了。
// 2.8.3 加回全屏大图清除，但上了一道安全闸门：
//   只有在"首页尚未挂载"（!gHomeMounted）时才清启动大图；一旦检测到首页内容（Flutter/
//   TabBar/WKWebView）就立刻永久停手，绝不再碰任何图。这样秒开回来了，首页也不会丢图。
// ============================================================================

static BOOL gHomeMounted = NO; // 首页是否已挂载；一旦为 YES 就永不清图

// 判断视图自身或任意祖先是否属于"启动页 / 开屏"命名族（精确词）
static BOOL isLaunchOrSplashView(UIView *view) {
    UIView *v = view;
    int depth = 0;
    while (v && depth < 12) {
        NSString *clsName = NSStringFromClass([v class]);
        if ([clsName containsString:@"Launch"] || [clsName containsString:@"Splash"]) {
            return YES;
        }
        v = v.superview;
        depth++;
    }
    return NO;
}

// 判断某个视图是否是真正的"首页容器"（包含 FlutterView / TabBar / WKWebView）
// 一旦命中就把 gHomeMounted 置位，之后所有清图逻辑立即失效
static BOOL isOrContainsHomeContent(UIView *view) {
    if (!view) return NO;
    NSString *clsName = NSStringFromClass([view class]);
    if ([clsName containsString:@"Flutter"] ||
        [clsName containsString:@"TabBar"] ||
        [clsName containsString:@"WKWebView"]) {
        gHomeMounted = YES;
        return YES;
    }
    UIResponder *next = [view nextResponder];
    if (next && [next isKindOfClass:[UIViewController class]]) {
        NSString *vcName = NSStringFromClass([next class]);
        if ([vcName containsString:@"Flutter"] ||
            [vcName containsString:@"TabBar"] ||
            [vcName containsString:@"Main"] ||
            [vcName containsString:@"Home"]) {
            gHomeMounted = YES;
            return YES;
        }
    }
    for (UIView *sub in view.subviews) {
        if (isOrContainsHomeContent(sub)) {
            gHomeMounted = YES;
            return YES;
        }
    }
    return NO;
}

// ============================================================================
// 1.5 时间加速（视图无关，天然不会白屏）
// ----------------------------------------------------------------------------
// 2.8.4 / 2.8.5 复盘：靠"隐藏窗口兄弟视图"找回秒开，接连误伤首页
// （内容区全白 → 彻底白屏）。既然视图层不可靠，就改回 2.7.0 的老办法：
// 不碰任何视图，只把启动期的"等待时间"压掉。用内联 fishhook 改写 Mach-O 的
// __la_symbol_ptr，劫持：
//   dispatch_after / dispatch_after_f → Swift 的 asyncAfter(deadline:) 立即执行
//   dispatch_source_set_timer        → GCD 倒计时瞬间走完
// 再配合 NSTimer 加速与 UIView 动画归零，开屏停留时间基本归 0。
// ============================================================================
#ifdef __LP64__
typedef struct mach_header_64 mach_header_t;
typedef struct segment_command_64 segment_command_t;
typedef struct section_64 section_t;
typedef struct nlist_64 nlist_t;
#define LC_SEGMENT_ARCH_DEPENDENT LC_SEGMENT_64
#else
typedef struct mach_header mach_header_t;
typedef struct segment_command segment_command_t;
typedef struct section section_t;
typedef struct nlist nlist_t;
#define LC_SEGMENT_ARCH_DEPENDENT LC_SEGMENT
#endif

struct rebinding_entry {
    const char *name;
    void *replacement;
    void **replaced;
};

static void perform_rebinding_with_section(struct rebinding_entry *rebindings, size_t rebindings_nel,
                                           section_t *section, intptr_t slide,
                                           nlist_t *symtab, char *strtab, uint32_t *indirect_symtab) {
    uint32_t *indirect_symbol_indices = indirect_symtab + section->reserved1;
    void **indirect_symbol_bindings = (void **)((uintptr_t)slide + section->addr);
    for (uint i = 0; i < section->size / sizeof(void *); i++) {
        uint32_t symtab_index = indirect_symbol_indices[i];
        if (symtab_index == INDIRECT_SYMBOL_ABS || symtab_index == INDIRECT_SYMBOL_LOCAL ||
            symtab_index == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) {
            continue;
        }
        uint32_t strtab_offset = symtab[symtab_index].n_un.n_strx;
        char *symbol_name = strtab + strtab_offset;
        if (symbol_name[0] == '\0') continue;

        for (size_t j = 0; j < rebindings_nel; j++) {
            if (strcmp(&symbol_name[1], rebindings[j].name) == 0) {
                if (rebindings[j].replaced != NULL && *rebindings[j].replaced == NULL) {
                    *rebindings[j].replaced = indirect_symbol_bindings[i];
                }
                indirect_symbol_bindings[i] = rebindings[j].replacement;
                break;
            }
        }
    }
}

static struct rebinding_entry kGlobalRebindings[5];
static size_t kGlobalRebindingsCount = 0;

static void rebind_symbols_for_image(const struct mach_header *header, intptr_t slide) {
    if (kGlobalRebindingsCount == 0) return;

    Dl_info info;
    if (dladdr(header, &info) == 0) return;
    // 只重绑定主程序与 Swift 的 GCD 桥接库，绝不碰系统底层框架
    if (info.dli_fname && strstr(info.dli_fname, "/System/Library/") != NULL) {
        if (strstr(info.dli_fname, "libswift") == NULL) {
            return;
        }
    }

    segment_command_t *cur_seg_cmd;
    segment_command_t *linkedit_segment = NULL;
    struct symtab_command *symtab_cmd = NULL;
    struct dysymtab_command *dysymtab_cmd = NULL;

    uintptr_t cur = (uintptr_t)header + sizeof(mach_header_t);
    for (uint i = 0; i < header->ncmds; i++, cur += cur_seg_cmd->cmdsize) {
        cur_seg_cmd = (segment_command_t *)cur;
        if (cur_seg_cmd->cmd == LC_SEGMENT_ARCH_DEPENDENT) {
            if (strcmp(cur_seg_cmd->segname, SEG_LINKEDIT) == 0) {
                linkedit_segment = cur_seg_cmd;
            }
        } else if (cur_seg_cmd->cmd == LC_SYMTAB) {
            symtab_cmd = (struct symtab_command *)cur_seg_cmd;
        } else if (cur_seg_cmd->cmd == LC_DYSYMTAB) {
            dysymtab_cmd = (struct dysymtab_command *)cur_seg_cmd;
        }
    }

    if (!symtab_cmd || !dysymtab_cmd || !linkedit_segment || !dysymtab_cmd->nindirectsyms) return;

    uintptr_t linkedit_base = (uintptr_t)slide + linkedit_segment->vmaddr - linkedit_segment->fileoff;
    nlist_t *symtab = (nlist_t *)(linkedit_base + symtab_cmd->symoff);
    char *strtab = (char *)(linkedit_base + symtab_cmd->stroff);
    uint32_t *indirect_symtab = (uint32_t *)(linkedit_base + dysymtab_cmd->indirectsymoff);

    cur = (uintptr_t)header + sizeof(mach_header_t);
    for (uint i = 0; i < header->ncmds; i++, cur += cur_seg_cmd->cmdsize) {
        cur_seg_cmd = (segment_command_t *)cur;
        if (cur_seg_cmd->cmd == LC_SEGMENT_ARCH_DEPENDENT) {
            if (strcmp(cur_seg_cmd->segname, SEG_DATA) != 0 &&
                strcmp(cur_seg_cmd->segname, "__DATA_CONST") != 0) {
                continue;
            }
            for (uint j = 0; j < cur_seg_cmd->nsects; j++) {
                section_t *sect = (section_t *)(cur + sizeof(segment_command_t)) + j;
                if ((sect->flags & SECTION_TYPE) == S_LAZY_SYMBOL_POINTERS) {
                    perform_rebinding_with_section(kGlobalRebindings, kGlobalRebindingsCount, sect, slide, symtab, strtab, indirect_symtab);
                }
            }
        }
    }
}

static void (*orig_dispatch_after)(dispatch_time_t when, dispatch_queue_t queue, dispatch_block_t block) = NULL;
static void (*orig_dispatch_after_f)(dispatch_time_t when, dispatch_queue_t queue, void *context, dispatch_function_t work) = NULL;
static void (*orig_dispatch_source_set_timer)(dispatch_source_t source, dispatch_time_t start, uint64_t interval, uint64_t leeway) = NULL;

static void hooked_dispatch_after(dispatch_time_t when, dispatch_queue_t queue, dispatch_block_t block) {
    // 启动前 4.5 秒内，主线程上 >0.15s 的延迟任务（开屏停留/闪屏等待）直接压到 1 毫秒
    if (CFAbsoluteTimeGetCurrent() - kAppLaunchTime < 4.5 && queue == dispatch_get_main_queue()) {
        dispatch_time_t now = dispatch_time(DISPATCH_TIME_NOW, 0);
        if (when > now + (int64_t)(0.15 * NSEC_PER_SEC)) {
            when = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.001 * NSEC_PER_SEC));
        }
    }
    if (orig_dispatch_after) {
        orig_dispatch_after(when, queue, block);
    }
}

static void hooked_dispatch_after_f(dispatch_time_t when, dispatch_queue_t queue, void *context, dispatch_function_t work) {
    // Swift 的 DispatchQueue.main.asyncAfter 走这里
    if (CFAbsoluteTimeGetCurrent() - kAppLaunchTime < 4.5 && queue == dispatch_get_main_queue()) {
        dispatch_time_t now = dispatch_time(DISPATCH_TIME_NOW, 0);
        if (when > now + (int64_t)(0.15 * NSEC_PER_SEC)) {
            when = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.001 * NSEC_PER_SEC));
        }
    }
    if (orig_dispatch_after_f) {
        orig_dispatch_after_f(when, queue, context, work);
    }
}

static void hooked_dispatch_source_set_timer(dispatch_source_t source, dispatch_time_t start, uint64_t interval, uint64_t leeway) {
    if (CFAbsoluteTimeGetCurrent() - kAppLaunchTime < 4.5) {
        dispatch_time_t now = dispatch_time(DISPATCH_TIME_NOW, 0);
        if (start > now + (int64_t)(0.15 * NSEC_PER_SEC)) {
            start = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.001 * NSEC_PER_SEC));
        }
        // 1 秒 1 次的开屏倒计时 → 0.01 秒 1 次，5 秒倒计时瞬间走完
        if (interval >= (uint64_t)(0.5 * NSEC_PER_SEC) && interval <= (uint64_t)(10.0 * NSEC_PER_SEC)) {
            interval = (uint64_t)(0.01 * NSEC_PER_SEC);
        }
    }
    if (orig_dispatch_source_set_timer) {
        orig_dispatch_source_set_timer(source, start, interval, leeway);
    }
}

// 2.8.7 诊断：统计主线程在 dispatch_semaphore_wait / dispatch_group_wait 上被阻塞的时长
// 只计时、不改变等待行为，用来判断"启动慢"到底卡在哪个原语上
static long (*orig_dispatch_semaphore_wait)(dispatch_semaphore_t dsema, dispatch_time_t timeout) = NULL;
static long (*orig_dispatch_group_wait)(dispatch_group_t group, dispatch_time_t timeout) = NULL;

static long hooked_dispatch_semaphore_wait(dispatch_semaphore_t dsema, dispatch_time_t timeout) {
    if (!orig_dispatch_semaphore_wait) return 0;
    if (CFAbsoluteTimeGetCurrent() - kAppLaunchTime < 12.0 && [NSThread isMainThread]) {
        CFAbsoluteTime a = CFAbsoluteTimeGetCurrent();
        long r = orig_dispatch_semaphore_wait(dsema, timeout);
        gBlkSem += CFAbsoluteTimeGetCurrent() - a;
        gCntSem++;
        return r;
    }
    return orig_dispatch_semaphore_wait(dsema, timeout);
}

static long hooked_dispatch_group_wait(dispatch_group_t group, dispatch_time_t timeout) {
    if (!orig_dispatch_group_wait) return 0;
    if (CFAbsoluteTimeGetCurrent() - kAppLaunchTime < 12.0 && [NSThread isMainThread]) {
        CFAbsoluteTime a = CFAbsoluteTimeGetCurrent();
        long r = orig_dispatch_group_wait(group, timeout);
        gBlkGrp += CFAbsoluteTimeGetCurrent() - a;
        gCntGrp++;
        return r;
    }
    return orig_dispatch_group_wait(group, timeout);
}

// ============================================================================
// 1. 清空"启动大图"以恢复秒开；首页一挂载就永久停手，绝不碰首页图片
// ============================================================================
%hook UIImageView

- (void)setImage:(UIImage *)image {
    if (image && (CFAbsoluteTimeGetCurrent() - kAppLaunchTime < 6.0)) {
        BOOL shouldStrip = NO;

        // (a) 明确是启动/开屏命名族里的图 → 永远清（这类只在开屏出现）
        if (isLaunchOrSplashView(self)) {
            shouldStrip = YES;
        }
        // (b) 首页还没挂载时，全屏竖版大图 = 启动页大图 → 清；首页一出现这条就永久失效
        else if (!gHomeMounted && !isOrContainsHomeContent(self)) {
            CGSize imgSize = image.size;
            CGSize screenSize = [UIScreen mainScreen].bounds.size;
            BOOL isFullScreenImage =
                (imgSize.width >= screenSize.width * 0.8 && imgSize.height >= screenSize.height * 0.65) ||
                (imgSize.width >= 600 && imgSize.height >= 1000);
            if (isFullScreenImage) {
                shouldStrip = YES;
            }
        }
        // (c) 兜底：任何情况下都不允许在启动期"顺手"改首页的图
        if (shouldStrip && !isOrContainsHomeContent(self)) {
            // 只做透明化隐藏，绝不 removeFromSuperview，避免 SnapKit 布局断言闪退
            %orig(nil);
            self.hidden = YES;
            self.alpha = 0.0;
            self.userInteractionEnabled = NO;
            UIView *container = self.superview;
            if (container &&
                ![container isKindOfClass:[UIWindow class]] &&
                !isOrContainsHomeContent(container)) {
                container.hidden = YES;
                container.alpha = 0.0;
                container.userInteractionEnabled = NO;
            }
            return;
        }
    }
    %orig(image);
}

%end


// ============================================================================
// 2. 开屏窗口：只拦 SDK 自建的 Splash 窗口，不再用宽松的 "Ad" 子串匹配
// ============================================================================
%hook UIWindow

- (void)addSubview:(UIView *)view {
    // 关键修复：先正常加入，再按精确类名隐藏；绝不"丢弃"，避免首页子视图被吞掉导致白屏
    %orig(view);
    if (view && (CFAbsoluteTimeGetCurrent() - kAppLaunchTime < 12.0)) {
        NSString *clsName = NSStringFromClass([view class]);
        if ([clsName containsString:@"Launch"] || [clsName containsString:@"Splash"]) {
            view.hidden = YES;
            view.alpha = 0.0;
            view.userInteractionEnabled = NO;
        }
    }
}

- (void)makeKeyAndVisible {
    NSString *clsName = NSStringFromClass([self class]);
    NSString *rootVC = self.rootViewController ? NSStringFromClass([self.rootViewController class]) : @"";
    if ([clsName containsString:@"Splash"] || [rootVC containsString:@"Splash"]) {
        self.hidden = YES;
        self.alpha = 0.0;
        self.userInteractionEnabled = NO;
        return;
    }
    %orig;
}

%end


// ============================================================================
// 3. 启动窗口期内取消过渡动画（秒开），之后恢复原始行为
// ============================================================================
%hook UIViewController

- (void)viewWillAppear:(BOOL)animated {
    NSString *vcName = NSStringFromClass([self class]);

    // 首页控制器出现 → 永久关闭清图逻辑（不再触碰任何视图）
    if ([vcName containsString:@"Flutter"] || [vcName containsString:@"Main"] ||
        [vcName containsString:@"Home"] || [vcName containsString:@"TabBar"]) {
        gHomeMounted = YES;
    }

    if (CFAbsoluteTimeGetCurrent() - kAppLaunchTime < 6.0) {
        %orig(NO);
        if ([vcName containsString:@"Launch"] || [vcName containsString:@"Splash"]) {
            self.view.hidden = YES;
            self.view.alpha = 0.0;
        }
    } else {
        %orig(animated);
    }
}

%end


// ============================================================================
// 4. 只按精确类名隐藏已知广告/开屏视图（删除"全屏即隐藏"启发式，避免误伤首页容器）
// ============================================================================
%hook UIView

- (void)didMoveToSuperview {
    %orig;
    if (!self.superview) return;

    NSString *clsName = NSStringFromClass([self class]);
    if (!clsName) return;

    // 首页视图（Flutter/TabBar/WKWebView）挂载 → 永久关闭清图逻辑（不再触碰任何视图）
    if ([clsName containsString:@"Flutter"] ||
        [clsName containsString:@"TabBar"] ||
        [clsName containsString:@"WKWebView"]) {
        gHomeMounted = YES;
    }

    if ([clsName containsString:@"LaunchView"] ||
        [clsName containsString:@"AdSplash"] ||
        [clsName containsString:@"SplashView"] ||
        [clsName containsString:@"AdDYCountdownView"] ||
        [clsName containsString:@"AdNativeView"] ||
        [clsName containsString:@"OrderAdCell"] ||
        [clsName containsString:@"MineNativeAdCell"] ||
        [clsName containsString:@"HXIconAdView"] ||
        [clsName containsString:@"LynxTobidFeedAdView"]) {

        self.hidden = YES;
        self.alpha = 0.0;
        self.userInteractionEnabled = NO;
    }
}

%end


// ============================================================================
// 4.5 时间加速（二）：NSTimer 加速 + 启动期动画归零
// 视图层完全不改，只压缩"等待"本身
// ============================================================================
%hook NSTimer

+ (NSTimer *)scheduledTimerWithTimeInterval:(NSTimeInterval)ti target:(id)aTarget selector:(SEL)aSelector userInfo:(id)userInfo repeats:(BOOL)yesOrNo {
    if (CFAbsoluteTimeGetCurrent() - kAppLaunchTime < 5.0 && ti >= 0.2 && ti <= 15.0) {
        ti = 0.005;
    }
    return %orig(ti, aTarget, aSelector, userInfo, yesOrNo);
}

+ (NSTimer *)scheduledTimerWithTimeInterval:(NSTimeInterval)interval repeats:(BOOL)repeats block:(void (^)(NSTimer *timer))block {
    if (CFAbsoluteTimeGetCurrent() - kAppLaunchTime < 5.0 && interval >= 0.2 && interval <= 15.0) {
        interval = 0.005;
    }
    return %orig(interval, repeats, block);
}

+ (NSTimer *)timerWithTimeInterval:(NSTimeInterval)interval repeats:(BOOL)repeats block:(void (^)(NSTimer *timer))block {
    if (CFAbsoluteTimeGetCurrent() - kAppLaunchTime < 5.0 && interval >= 0.2 && interval <= 15.0) {
        interval = 0.005;
    }
    return %orig(interval, repeats, block);
}

+ (NSTimer *)timerWithTimeInterval:(NSTimeInterval)ti target:(id)aTarget selector:(SEL)aSelector userInfo:(id)userInfo repeats:(BOOL)yesOrNo {
    if (CFAbsoluteTimeGetCurrent() - kAppLaunchTime < 5.0 && ti >= 0.2 && ti <= 15.0) {
        ti = 0.005;
    }
    return %orig(ti, aTarget, aSelector, userInfo, yesOrNo);
}

%end

%hook UIView

+ (void)animateWithDuration:(NSTimeInterval)duration animations:(void (^)(void))animations completion:(void (^)(BOOL finished))completion {
    if (CFAbsoluteTimeGetCurrent() - kAppLaunchTime < 5.0) {
        duration = 0.0;
    }
    %orig(duration, animations, completion);
}

+ (void)animateWithDuration:(NSTimeInterval)duration delay:(NSTimeInterval)delay options:(UIViewAnimationOptions)options animations:(void (^)(void))animations completion:(void (^)(BOOL finished))completion {
    if (CFAbsoluteTimeGetCurrent() - kAppLaunchTime < 5.0) {
        duration = 0.0;
        delay = 0.0;
    }
    %orig(duration, delay, options, animations, completion);
}

%end

// 2.8.7 诊断：统计 NSThread 睡眠（有些 SDK 用 [NSThread sleepForTimeInterval:] 等待）
%hook NSThread
+ (void)sleepForTimeInterval:(NSTimeInterval)ti {
    if (CFAbsoluteTimeGetCurrent() - kAppLaunchTime < 12.0 && [NSThread isMainThread]) {
        CFAbsoluteTime a = CFAbsoluteTimeGetCurrent();
        %orig(ti);
        gBlkSlp += CFAbsoluteTimeGetCurrent() - a;
        gCntSlp++;
    } else {
        %orig(ti);
    }
}
%end


// ============================================================================
// 5. 网络层继续保持 100% 拦截所有第三方广告与小蚕 AdMobileService
// ============================================================================
static NSString * const kBlockedAdHosts[] = {
    @"leadmoad.com", @"adbiding.com", @"tobidad.cn", @"tobidad.com",
    @"sigmob.cn", @"pangolin-sdk-toutiao", @"pglstatp-toutiao.com",
    @"ctobsnssdk.com", @"oceanengine.com", @"bdurl.net", @"bytescm.com",
    @"bytegoofy.com", @"volces.com", @"zijieapi.com", @"douyin.com",
    @"douyinstatic.com", @"gdt.qq.com", @"e.qq.com", @"ugdtimg.com",
    @"gdtimg.com", @"mobads.baidu.com", @"als.baidu.com", @"pos.baidu.com",
    @"beizi.biz", @"adn-plus.com.cn", @"ad-scope.com.cn", @"mentamob.com",
    @"advlion.com", @"vlion.cn", @"fibo.cn", @"fancydsp.com", @"fancyapi.com",
    @"dmrtb.com", @"richmob.cn", @"ubixioe.com", @"tanx.com", @"1rtb.net",
    @"1rtb.com", @"yunxish.com", @"58iclick.com", @"iggrowth.cn",
    @"innotechx.com", @"etoolads.cn", @"zhangyuyidong.cn", @"hubcloud.com.cn",
    @"nwiztech.com", @"kuaishou.com", @"gifshow.com",
    @"iadsdk.apple.com", @"adservices.apple.com"
};

static const size_t kBlockedAdHostsCount = sizeof(kBlockedAdHosts) / sizeof(kBlockedAdHosts[0]);

static BOOL shouldBlockAdURL(NSURL *url) {
    if (!url || ![url isKindOfClass:[NSURL class]]) return NO;
    NSString *host = [url host];
    if (!host || ![host isKindOfClass:[NSString class]] || host.length == 0) return NO;
    NSString *lowerHost = [host lowercaseString];
    for (size_t i = 0; i < kBlockedAdHostsCount; i++) {
        if ([lowerHost containsString:kBlockedAdHosts[i]]) {
            return YES;
        }
    }
    return NO;
}

static BOOL isXiaoCanAdRPC(NSURLRequest *request) {
    if (!request || !request.URL) return NO;
    if (![[request.URL.absoluteString lowercaseString] containsString:@"gw.xiaocantech.com/rpc"]) return NO;
    NSString *methodName = [request valueForHTTPHeaderField:@"methodname"] ?: @"";
    NSString *serverName = [request valueForHTTPHeaderField:@"servername"] ?: @"";
    if ([methodName containsString:@"MatchPlacement"] || [methodName containsString:@"AdMobileService"] || [serverName isEqualToString:@"SilkwormAd"]) {
        return YES;
    }
    return NO;
}

@interface XCFastAdBlockProtocol : NSURLProtocol
@end

@implementation XCFastAdBlockProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if ([NSURLProtocol propertyForKey:@"XCAdHandled" inRequest:request]) return NO;
    if (isXiaoCanAdRPC(request) || shouldBlockAdURL(request.URL)) return YES;
    return NO;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }

- (void)startLoading {
    NSMutableURLRequest *mutableReq = [self.request mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:@"XCAdHandled" inRequest:mutableReq];
    if (isXiaoCanAdRPC(self.request)) {
        NSData *data = [@"{\"status\":{\"code\":0},\"data\":{\"ad_open\":0,\"ad_type\":[],\"ad_source\":[],\"ios_slot_id\":\"\",\"put_id\":0}}" dataUsingEncoding:NSUTF8StringEncoding];
        NSHTTPURLResponse *resp = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Content-Type": @"application/json"}];
        [self.client URLProtocol:self didReceiveResponse:resp cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        [self.client URLProtocol:self didLoadData:data];
        [self.client URLProtocolDidFinishLoading:self];
        return;
    }
    [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]];
}

- (void)stopLoading {}
@end

%hook NSURLSession
+ (NSURLSession *)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration delegate:(id<NSURLSessionDelegate>)delegate delegateQueue:(NSOperationQueue *)queue {
    if (configuration) {
        NSMutableArray *protocols = configuration.protocolClasses ? [configuration.protocolClasses mutableCopy] : [NSMutableArray array];
        if (![protocols containsObject:[XCFastAdBlockProtocol class]]) {
            [protocols insertObject:[XCFastAdBlockProtocol class] atIndex:0];
            configuration.protocolClasses = protocols;
        }
    }
    return %orig(configuration, delegate, queue);
}
%end

%hook CMMotionManager
- (void)startAccelerometerUpdates {}
- (void)startAccelerometerUpdatesToQueue:(NSOperationQueue *)queue withHandler:(CMAccelerometerHandler)handler {}
- (void)startGyroUpdates {}
- (void)startGyroUpdatesToQueue:(NSOperationQueue *)queue withHandler:(CMGyroHandler)handler {}
- (void)startDeviceMotionUpdates {}
- (void)startDeviceMotionUpdatesToQueue:(NSOperationQueue *)queue withHandler:(CMDeviceMotionHandler)handler {}
%end

// ============================================================================
// 6. 启动诊断面层（2.8.7 临时，只看不改）
// ----------------------------------------------------------------------------
// 前几版一直在"秒进 / 白屏 / 丢图"之间摇摆，根因始终没坐实。这一版不加任何去广告/
// 加速功能，只把"启动到底卡在哪"直接画在屏幕上：
//   (1) t=… bg=… main=…  → bg 一直涨、main 不动 = 主线程被阻塞（卡住）
//   (2) 每个 UIWindow 的真实类名 / 顶层视图链 / 是否已含首页(Flutter/TabBar/Lynx)
//   (3) 启动期阻塞原语的调用次数与累计秒数：sem=信号量 grp=DispatchGroup slp=睡眠
// 请截两张图：约 2 秒时一张、约 5～6 秒时一张。30 秒后自动消失。
// ============================================================================
static UIWindow *gDiagWindow = nil;
static UILabel *gDiagLabel = nil;
static volatile int gBgTick = 0, gMainTick = 0, gMainPending = 0;
static volatile BOOL gDiagReady = NO;

static NSString *xcDiagTopChain(UIView *root, int depth) {
    NSMutableString *chain = [NSMutableString string];
    UIView *v = root;
    for (int i = 0; i < depth; i++) {
        if (v.subviews.count == 0) break;
        v = v.subviews.lastObject;
        [chain appendFormat:@"%@>", NSStringFromClass([v class])];
    }
    return chain;
}

static BOOL xcDiagHasHome(UIView *view, int depth) {
    if (!view || depth > 20) return NO;
    NSString *cls = NSStringFromClass([view class]);
    if ([cls containsString:@"Flutter"] || [cls containsString:@"TabBar"] ||
        [cls containsString:@"WKWebView"] || [cls containsString:@"Lynx"]) {
        return YES;
    }
    for (UIView *sub in view.subviews) {
        if (xcDiagHasHome(sub, depth + 1)) return YES;
    }
    return NO;
}

static NSString *xcDiagText(void) {
    NSMutableString *s = [NSMutableString string];
    double el = CFAbsoluteTimeGetCurrent() - kAppLaunchTime;
    int lag = gBgTick - gMainTick;
    [s appendFormat:@"t=%.1fs bg=%d main=%d %@\n", el, gBgTick, gMainTick,
        (lag > 2 ? @"<<主线程被阻塞>>" : @"主线程在跑")];
    [s appendFormat:@"blk sem=%d(%.1fs) grp=%d(%.1fs) slp=%d(%.1fs)\n",
        gCntSem, gBlkSem, gCntGrp, gBlkGrp, gCntSlp, gBlkSlp];

    NSArray<UIWindow *> *wins = [UIApplication sharedApplication].windows;
    [s appendFormat:@"windows=%lu\n", (unsigned long)wins.count];
    int idx = 0;
    for (UIWindow *w in wins) {
        if (idx >= 3) break;
        NSString *vc = w.rootViewController ? NSStringFromClass([w.rootViewController class]) : @"-";
        [s appendFormat:@"W%d %@ h%d%@\n  vc=%@\n  >%@\n  home=%d\n",
            idx, NSStringFromClass([w class]), (int)w.hidden,
            (w.isKeyWindow ? @" KEY" : @""), vc,
            xcDiagTopChain(w, 5), (int)xcDiagHasHome(w, 0)];
        idx++;
    }
    return s;
}

static void xcDiagSetup(void) {
    CGRect scr = [UIScreen mainScreen].bounds;
    CGFloat h = 340;
    gDiagWindow = [[UIWindow alloc] initWithFrame:CGRectMake(0, 48, scr.size.width, h)];
    gDiagWindow.windowLevel = UIWindowLevelAlert + 100;
    gDiagWindow.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.72];
    gDiagWindow.userInteractionEnabled = NO;
    UIViewController *vc = [[UIViewController alloc] init];
    gDiagWindow.rootViewController = vc;
    gDiagLabel = [[UILabel alloc] initWithFrame:CGRectMake(4, 2, scr.size.width - 8, h - 4)];
    gDiagLabel.numberOfLines = 0;
    gDiagLabel.textColor = [UIColor colorWithRed:0.4 green:1.0 blue:0.4 alpha:1.0];
    UIFont *f = [UIFont fontWithName:@"Menlo" size:9.0];
    gDiagLabel.font = f ?: [UIFont systemFontOfSize:9.0];
    gDiagLabel.text = @"diag booting...";
    [vc.view addSubview:gDiagLabel];
    gDiagWindow.hidden = NO;
    gDiagReady = YES;
}

static void xcDiagStart(void) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        for (;;) {
            usleep(300 * 1000);
            gBgTick++;
            // 后台每 0.3s 往主线程塞一次刷新；主线程被阻塞时这里就不会执行 → main 计数停住
            if (!gMainPending) {
                gMainPending = 1;
                dispatch_async(dispatch_get_main_queue(), ^{
                    gMainPending = 0;
                    gMainTick++;
                    if (!gDiagReady) {
                        for (UIWindow *w in [UIApplication sharedApplication].windows) {
                            if (w.isKeyWindow) { xcDiagSetup(); break; }
                        }
                    }
                    if (gDiagReady) gDiagLabel.text = xcDiagText();
                });
            }
            if (CFAbsoluteTimeGetCurrent() - kAppLaunchTime > 30.0) break;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            gDiagLabel.hidden = YES;
            gDiagWindow.hidden = YES;
        });
    });
}

%ctor {
    @autoreleasepool {
        kAppLaunchTime = CFAbsoluteTimeGetCurrent();

        // 1. 注册网络协议拦截器
        [NSURLProtocol registerClass:[XCFastAdBlockProtocol class]];

        // 2. 内联 fishhook：重绑定主程序与 Swift 库里的 dispatch_after / dispatch_after_f /
        //    dispatch_source_set_timer，把启动期的等待时间压到 1 毫秒
        kGlobalRebindings[0] = (struct rebinding_entry){ "dispatch_after", (void *)hooked_dispatch_after, (void **)&orig_dispatch_after };
        kGlobalRebindings[1] = (struct rebinding_entry){ "dispatch_after_f", (void *)hooked_dispatch_after_f, (void **)&orig_dispatch_after_f };
        kGlobalRebindings[2] = (struct rebinding_entry){ "dispatch_source_set_timer", (void *)hooked_dispatch_source_set_timer, (void **)&orig_dispatch_source_set_timer };
        // 3. 诊断：统计（不改变）主线程在信号量/组等待上的阻塞
        if (!orig_dispatch_semaphore_wait) orig_dispatch_semaphore_wait = (long (*)(dispatch_semaphore_t, dispatch_time_t))dlsym(RTLD_DEFAULT, "dispatch_semaphore_wait");
        if (!orig_dispatch_group_wait) orig_dispatch_group_wait = (long (*)(dispatch_group_t, dispatch_time_t))dlsym(RTLD_DEFAULT, "dispatch_group_wait");
        kGlobalRebindings[3] = (struct rebinding_entry){ "dispatch_semaphore_wait", (void *)hooked_dispatch_semaphore_wait, (void **)&orig_dispatch_semaphore_wait };
        kGlobalRebindings[4] = (struct rebinding_entry){ "dispatch_group_wait", (void *)hooked_dispatch_group_wait, (void **)&orig_dispatch_group_wait };
        kGlobalRebindingsCount = 5;

        _dyld_register_func_for_add_image(rebind_symbols_for_image);

        // 4. 启动诊断面层
        xcDiagStart();
    }
}
