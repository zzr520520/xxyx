#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreMotion/CoreMotion.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <dlfcn.h>

static CFAbsoluteTime kProcessStartTime = 0;

// ============================================================================
// 第一部分：内联轻量级 Fishhook (解决非越狱 Esign 注入下 %hookf 不生效的致命问题！)
// 直接修改 Mach-O 的 __la_symbol_ptr / __got 表，100% 劫持 Swift 的 dispatch_after_f！
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
                // 修改内存页权限并写入新函数指针（兼容 iOS 14+ __DATA_CONST）
                indirect_symbol_bindings[i] = rebindings[j].replacement;
                break;
            }
        }
    }
}

static struct rebinding_entry kGlobalRebindings[3];
static size_t kGlobalRebindingsCount = 0;

static void rebind_symbols_for_image(const struct mach_header *header, intptr_t slide) {
    if (kGlobalRebindingsCount == 0) return;
    
    Dl_info info;
    if (dladdr(header, &info) == 0) return;
    // 只重绑定主程序 xiaocan 和 XiaoCanAd 等非系统库，避免破坏系统底层框架
    if (info.dli_fname && strstr(info.dli_fname, "/System/Library/") != NULL) {
        // 但 libswiftDispatch.dylib 是 Swift 调用 GCD 的桥梁，必须重绑定它！
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

// ============================================================================
// 第二部分：劫持 Swift 的 dispatch_after_f / dispatch_after / dispatch_source_set_timer
// 为什么抓包里从 14:37:22 到 14:37:25 空转了 3 秒才请求首页？
// 因为 Swift 的 LaunchUtil / AdManager 调用了 asyncAfter(deadline: .now() + 3.0)！
// 而 Swift 的 asyncAfter 底层调用的是 dispatch_after_f，我们直接把延迟时间改成 0！
// ============================================================================
static void (*orig_dispatch_after)(dispatch_time_t when, dispatch_queue_t queue, dispatch_block_t block) = NULL;
static void (*orig_dispatch_after_f)(dispatch_time_t when, dispatch_queue_t queue, void *context, dispatch_function_t work) = NULL;
static void (*orig_dispatch_source_set_timer)(dispatch_source_t source, dispatch_time_t start, uint64_t interval, uint64_t leeway) = NULL;

static void hooked_dispatch_after(dispatch_time_t when, dispatch_queue_t queue, dispatch_block_t block) {
    // 启动前 4.5 秒内，凡是在主线程排队的 >0.15s 的延迟任务（开屏等待/闪屏停留），直接变成 1毫秒 立即执行！
    if (CFAbsoluteTimeGetCurrent() - kProcessStartTime < 4.5 && queue == dispatch_get_main_queue()) {
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
    // Swift 的 DispatchQueue.main.asyncAfter 100% 走这里！
    if (CFAbsoluteTimeGetCurrent() - kProcessStartTime < 4.5 && queue == dispatch_get_main_queue()) {
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
    // Swift 的 DispatchSourceTimer 倒计时 100% 走这里！
    if (CFAbsoluteTimeGetCurrent() - kProcessStartTime < 4.5) {
        dispatch_time_t now = dispatch_time(DISPATCH_TIME_NOW, 0);
        if (start > now + (int64_t)(0.15 * NSEC_PER_SEC)) {
            start = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.001 * NSEC_PER_SEC));
        }
        // 如果是 1秒1次 的开屏倒计时，把它加速到 0.01秒1次，让 5秒倒计时在 0.05秒内走完！
        if (interval >= (uint64_t)(0.5 * NSEC_PER_SEC) && interval <= (uint64_t)(10.0 * NSEC_PER_SEC)) {
            interval = (uint64_t)(0.01 * NSEC_PER_SEC);
        }
    }
    if (orig_dispatch_source_set_timer) {
        orig_dispatch_source_set_timer(source, start, interval, leeway);
    }
}


// ============================================================================
// 第三部分：网络层拦截 (不仅拦广告，还直接秒回启动期的慢速非核心配置请求！)
// 抓包显示启动期 ExperimentService.CheckUserInGroup / version.json / cloudconf 也在拖慢进首页速度
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
    @"iadsdk.apple.com", @"adservices.apple.com",
    @"sensorsdata.xiaocanapp.com", // 埋点上报直接拦截，省去启动网络开销
    @"ido.gepush.com"              // 个推 SDK 启动上报直接拦截，加速冷启动
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

// 拦截小蚕网关的所有广告、AB实验（tobid-1）、开屏配置 RPC，0毫秒本地秒回！
static NSString *getFakeRPCResponseIfNeeded(NSURLRequest *request) {
    if (!request || !request.URL) return nil;
    NSString *absURL = [request.URL.absoluteString lowercaseString];
    
    // 1. 拦截网关 RPC 中的广告与开屏实验
    if ([absURL containsString:@"gw.xiaocantech.com/rpc"]) {
        NSString *methodName = [request valueForHTTPHeaderField:@"methodname"] ?: @"";
        NSString *serverName = [request valueForHTTPHeaderField:@"servername"] ?: @"";
        
        // 开屏广告位匹配 -> 秒回 ad_open: 0
        if ([methodName containsString:@"MatchPlacement"] || [serverName isEqualToString:@"SilkwormAd"]) {
            if ([methodName containsString:@"GetUserInfo"]) {
                return @"{\"status\":{\"code\":0},\"data\":{\"module_open\":0,\"show_exchange_silk_entry\":false}}";
            }
            return @"{\"status\":{\"code\":0},\"data\":{\"ad_open\":0,\"ad_type\":[],\"ad_source\":[],\"ios_slot_id\":\"\",\"put_id\":0}}";
        }
        // 苹果广告归因监控 -> 秒回成功
        if ([serverName isEqualToString:@"SilkwormAdMonitor"]) {
            return @"{\"status\":{\"code\":0}}";
        }
        // 新人弹窗 / 营销弹窗 / VIP弹窗 -> 全部秒回不展示 (防止进首页后跳出弹窗！)
        if ([methodName isEqualToString:@"NewUserMobileService.IsNewUserAndShowPopup"]) {
            return @"{\"status\":{\"code\":0},\"activity\":{\"show\":false,\"users\":null,\"is_new_user\":false,\"source\":0}}";
        }
        if ([methodName isEqualToString:@"NewUserMobileService.IsShowOrderAwardPopup"]) {
            return @"{\"status\":{\"code\":0},\"show\":false,\"order_tip\":null,\"is_new_user\":false,\"target_show\":false,\"target_order_tip\":null}";
        }
        if ([methodName isEqualToString:@"SilkwormMobileMarketingService.GetUserMarketingInfoV2"]) {
            return @"{\"status\":{\"code\":0},\"if_receive_add_gift\":false,\"if_promotion_muster\":false,\"if_force_screen\":false,\"if_celebrate\":false,\"if_page_gift\":false}";
        }
        if ([methodName isEqualToString:@"SilkwormVipMobile.VipPopup"]) {
            return @"{\"status\":{\"code\":0},\"list\":[{\"is_showed\":true,\"popup_type\":5}]}";
        }
        // 启动期耗时 300ms 的 AB 实验分组检查 (ExperimentService.CheckUserInGroup) -> 本地 0ms 秒回对照组，不走网络等待！
        if ([methodName isEqualToString:@"ExperimentService.CheckUserInGroup"]) {
            return @"{\"status\":{\"code\":0},\"group\":{\"id\":540,\"name\":\"A\",\"weight\":50,\"context\":\"{}\",\"white_list\":null,\"is_control\":true}}";
        }
    }
    
    // 2. 启动期耗时 463ms 的 native_order_config.json -> 本地 0ms 秒回！
    if ([absURL containsString:@"native_order_config.json"]) {
        return @"{\"open_native\":true,\"open_ios_native\":true,\"open_android_native\":true,\"open_ohos_native\":true,\"open_flutter_native\":true}";
    }
    // 3. 启动期耗时 426ms 的停机检查 server_downtime.json -> 本地 0ms 秒回！
    if ([absURL containsString:@"server_downtime.json"]) {
        return @"{\"message\":\"\",\"open\":false}";
    }
    
    return nil;
}

@interface XCSuperFastProtocol : NSURLProtocol
@end

@implementation XCSuperFastProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if ([NSURLProtocol propertyForKey:@"XCFastHandled" inRequest:request]) return NO;
    if (getFakeRPCResponseIfNeeded(request) != nil || shouldBlockAdURL(request.URL)) {
        return YES;
    }
    return NO;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSMutableURLRequest *mutableReq = [self.request mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:@"XCFastHandled" inRequest:mutableReq];
    
    NSString *fakeJson = getFakeRPCResponseIfNeeded(self.request);
    if (fakeJson) {
        NSData *data = [fakeJson dataUsingEncoding:NSUTF8StringEncoding];
        NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                                                  statusCode:200
                                                                 HTTPVersion:@"HTTP/1.1"
                                                                headerFields:@{@"Content-Type": @"application/json"}];
        [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        [self.client URLProtocol:self didLoadData:data];
        [self.client URLProtocolDidFinishLoading:self];
        return;
    }
    
    NSError *cancelErr = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil];
    [self.client URLProtocol:self didFailWithError:cancelErr];
}

- (void)stopLoading {}

@end

%hook NSURLSession

+ (NSURLSession *)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration delegate:(id<NSURLSessionDelegate>)delegate delegateQueue:(NSOperationQueue *)queue {
    if (configuration) {
        NSMutableArray *protocols = configuration.protocolClasses ? [configuration.protocolClasses mutableCopy] : [NSMutableArray array];
        if (![protocols containsObject:[XCSuperFastProtocol class]]) {
            [protocols insertObject:[XCSuperFastProtocol class] atIndex:0];
            configuration.protocolClasses = protocols;
        }
    }
    return %orig(configuration, delegate, queue);
}

+ (NSURLSession *)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration {
    if (configuration) {
        NSMutableArray *protocols = configuration.protocolClasses ? [configuration.protocolClasses mutableCopy] : [NSMutableArray array];
        if (![protocols containsObject:[XCSuperFastProtocol class]]) {
            [protocols insertObject:[XCSuperFastProtocol class] atIndex:0];
            configuration.protocolClasses = protocols;
        }
    }
    return %orig(configuration);
}

%end


// ============================================================================
// 第四部分：解决纯 Swift 类 (xiaocan.LaunchUtil / xiaocan.AdManager) 不走 NSObject 的问题！
// 既然它们继承自 Swift._SwiftObject，我们就扫描内存中的 Ivar 偏移，并劫持 UIViewController 生命周期！
// ============================================================================
%hook NSTimer

+ (NSTimer *)scheduledTimerWithTimeInterval:(NSTimeInterval)ti target:(id)aTarget selector:(SEL)aSelector userInfo:(id)userInfo repeats:(BOOL)yesOrNo {
    if (CFAbsoluteTimeGetCurrent() - kProcessStartTime < 5.0) {
        // 启动前 5 秒内，无论是重复的 1s 倒计时还是单次的 3~8s 超时，统统加速到 0.005 秒！
        if (ti >= 0.2 && ti <= 15.0) {
            ti = 0.005;
        }
    }
    return %orig(ti, aTarget, aSelector, userInfo, yesOrNo);
}

+ (NSTimer *)scheduledTimerWithTimeInterval:(NSTimeInterval)interval repeats:(BOOL)repeats block:(void (^)(NSTimer *timer))block {
    if (CFAbsoluteTimeGetCurrent() - kProcessStartTime < 5.0) {
        if (interval >= 0.2 && interval <= 15.0) {
            interval = 0.005;
        }
    }
    return %orig(interval, repeats, block);
}

+ (NSTimer *)timerWithTimeInterval:(NSTimeInterval)interval repeats:(BOOL)repeats block:(void (^)(NSTimer *timer))block {
    if (CFAbsoluteTimeGetCurrent() - kProcessStartTime < 5.0) {
        if (interval >= 0.2 && interval <= 15.0) {
            interval = 0.005;
        }
    }
    return %orig(interval, repeats, block);
}

+ (NSTimer *)timerWithTimeInterval:(NSTimeInterval)ti target:(id)aTarget selector:(SEL)aSelector userInfo:(id)userInfo repeats:(BOOL)yesOrNo {
    if (CFAbsoluteTimeGetCurrent() - kProcessStartTime < 5.0) {
        if (ti >= 0.2 && ti <= 15.0) {
            ti = 0.005;
        }
    }
    return %orig(ti, aTarget, aSelector, userInfo, yesOrNo);
}

%end

// 消除启动期一切 UIView 渐隐动画耗时
%hook UIView

+ (void)animateWithDuration:(NSTimeInterval)duration animations:(void (^)(void))animations completion:(void (^)(BOOL finished))completion {
    if (CFAbsoluteTimeGetCurrent() - kProcessStartTime < 5.0) {
        duration = 0.0;
    }
    %orig(duration, animations, completion);
}

+ (void)animateWithDuration:(NSTimeInterval)duration delay:(NSTimeInterval)delay options:(UIViewAnimationOptions)options animations:(void (^)(void))animations completion:(void (^)(BOOL finished))completion {
    if (CFAbsoluteTimeGetCurrent() - kProcessStartTime < 5.0) {
        duration = 0.0;
        delay = 0.0;
    }
    %orig(duration, delay, options, animations, completion);
}

- (void)didMoveToSuperview {
    %orig;
    if (!self.superview) return;
    NSString *clsName = NSStringFromClass([self class]);
    if (!clsName) return;
    
    // 拦截信息流及开屏视图
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
        if (![self isKindOfClass:[UITableViewCell class]] && ![self isKindOfClass:[UICollectionViewCell class]]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self removeFromSuperview];
            });
        }
    }
}

%end

// 拦截独立 adWindow
%hook UIWindow

- (void)makeKeyAndVisible {
    NSString *clsName = NSStringFromClass([self class]);
    NSString *rootVC = self.rootViewController ? NSStringFromClass([self.rootViewController class]) : @"";
    if ([clsName containsString:@"Splash"] || [clsName containsString:@"Ad"] ||
        [rootVC containsString:@"Splash"] || [rootVC containsString:@"AdSplash"]) {
        self.hidden = YES;
        self.alpha = 0.0;
        self.userInteractionEnabled = NO;
        return;
    }
    %orig;
}

%end

// ============================================================================
// 第五部分：禁用摇一摇与入口初始化
// ============================================================================
%hook CMMotionManager
- (void)startAccelerometerUpdates {}
- (void)startAccelerometerUpdatesToQueue:(NSOperationQueue *)queue withHandler:(CMAccelerometerHandler)handler {}
- (void)startGyroUpdates {}
- (void)startGyroUpdatesToQueue:(NSOperationQueue *)queue withHandler:(CMGyroHandler)handler {}
- (void)startDeviceMotionUpdates {}
- (void)startDeviceMotionUpdatesToQueue:(NSOperationQueue *)queue withHandler:(CMDeviceMotionHandler)handler {}
%end

%ctor {
    @autoreleasepool {
        kProcessStartTime = CFAbsoluteTimeGetCurrent();
        
        // 1. 注册网络协议拦截器
        [NSURLProtocol registerClass:[XCSuperFastProtocol class]];
        
        // 2. 启动内联 Fishhook，重绑定主二进制与 Swift 库中的 dispatch_after_f / dispatch_after / dispatch_source_set_timer
        kGlobalRebindings[0] = (struct rebinding_entry){ "dispatch_after", (void *)hooked_dispatch_after, (void **)&orig_dispatch_after };
        kGlobalRebindings[1] = (struct rebinding_entry){ "dispatch_after_f", (void *)hooked_dispatch_after_f, (void **)&orig_dispatch_after_f };
        kGlobalRebindings[2] = (struct rebinding_entry){ "dispatch_source_set_timer", (void *)hooked_dispatch_source_set_timer, (void **)&orig_dispatch_source_set_timer };
        kGlobalRebindingsCount = 3;
        
        _dyld_register_func_for_add_image(rebind_symbols_for_image);
    }
}
