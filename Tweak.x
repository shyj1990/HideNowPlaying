// HideNowPlaying v0.0.8 — 锁屏结构侦察版
//
// v0.0.7 真机日志重大发现(iPhone 15 Pro / iOS 17.0 / relaxin):
//   MRUNowPlayingViewController 的视图层级链是
//     MRUNowPlayingView(159x159) <- UIView <- MRUControlCenterView <- CCUIContentModuleContentContainerView
//   → 它是"控制中心"的正在播放模块磁贴, 不是锁屏播放卡片!
//   锁屏上真正显示的播放卡片来自其它类(嫌疑: MediaControls* / MPUControlCenterMediaModule*),
//   只在"媒体播放+锁屏"时才加载, 注销瞬间探测不到。
//
// v0.0.8 做法: 插件盯着播放状态, 每当"开始播放"→ 3 秒后自动把 SpringBoard 所有窗口里
//   媒体相关的可见视图子树写进日志(每 15 秒最多一次, 最多 3 次)。
//   用户操作: 放歌 → 锁屏 → 等半分钟 → 同步日志, 即可拿到锁屏播放卡片真实类名和层级。
//
// 隐藏/恢复机制本版处于休眠状态(等待侦察结果后在下一版启用)。
// 日志: /var/mobile/Documents/HideNowPlaying.log

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <stdlib.h>

#pragma mark - 前置声明

static void HNPMReconDump(NSString *reason);

#pragma mark - 日志

static void HNPMAppendLog(NSString *text) {
    @try {
        NSString *path = @"/var/mobile/Documents/HideNowPlaying.log";
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], text];
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:path]) {
            [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } else {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
            if (fh) {
                [fh seekToEndOfFile];
                [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
                [fh closeFile];
            }
        }
        NSLog(@"[HideNowPlaying] %@", text);
    } @catch (NSException *exception) {
        // 任何情况下日志都不能让插件崩溃
    }
}

static void HNPMLogThrottled(NSString *text) {
    @try {
        static CFAbsoluteTime last = 0;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - last < 1.0) return;
        last = now;
        HNPMAppendLog(text);
    } @catch (NSException *e) {}
}

#pragma mark - 全局状态

static NSTimer *hnpmTimer = nil;             // 1 秒轮询定时器
static BOOL hnpmPrevPlaying = NO;            // 上一秒是否在播放
static int hnpmDumpCount = 0;                // 已侦察次数(最多 3 次)
static CFAbsoluteTime hnpmLastDump = 0;      // 上次侦察时间
static NSHashTable *hnpmCardViews = nil;     // 弱引用表: 疑似锁屏卡片视图(下一版用)
static NSHashTable *hnpmAmbientViews = nil;  // 弱引用表: 疑似灵动岛视图(下一版用)

#pragma mark - MediaRemote(运行时 dlopen, 无需链接参数)

typedef void (*HNPMGetInfoFunc)(dispatch_queue_t, void (^)(CFDictionaryRef));
static HNPMGetInfoFunc hnpmGetInfo = NULL;

#pragma mark - 视图树侦察

// 是否为"值得侦察"的节点: 可见 + 有实际尺寸 + 类名含媒体关键词
static BOOL HNPMInteresting(UIView *v) {
    @try {
        if (!v || v.hidden || v.alpha < 0.05) return NO;
        if (v.frame.size.width < 40 || v.frame.size.height < 40) return NO;
        NSString *n = NSStringFromClass([v class]);
        return ([n containsString:@"Media"] || [n containsString:@"NowPlaying"] ||
                [n containsString:@"Controls"] || [n containsString:@"Player"] ||
                [n containsString:@"Ambient"] || [n containsString:@"Backdrop"] ||
                [n containsString:@"DashBoard"] || [n containsString:@"Island"]);
    } @catch (NSException *e) { return NO; }
}

// 输出一棵子树(带缩进/尺寸/手势列表)
static void HNPMSubtree(UIView *v, NSMutableString *out, NSInteger depth, NSInteger *count) {
    @try {
        if (!v || *count > 100 || depth > 6) return;
        (*count)++;
        NSString *indent = depth > 0 ? [@"" stringByPaddingToLength:(NSUInteger)(depth * 2) withString:@" " startingAtIndex:0] : @"";
        [out appendFormat:@"%@%@ frame=%@ hidden=%d alpha=%.1f userInt=%d",
         indent, NSStringFromClass([v class]), NSStringFromCGRect(v.frame),
         v.hidden ? 1 : 0, v.alpha, v.userInteractionEnabled ? 1 : 0];
        NSArray *grs = [v gestureRecognizers];
        if (grs.count > 0) {
            NSMutableArray *names = [NSMutableArray array];
            for (UIGestureRecognizer *g in grs) [names addObject:NSStringFromClass([g class])];
            [out appendFormat:@" GR<%@>", [names componentsJoinedByString:@","]];
        }
        [out appendString:@"\n"];
        for (UIView *s in [v subviews]) HNPMSubtree(s, out, depth + 1, count);
    } @catch (NSException *e) {}
}

// 递归搜索: 命中关键词的可见节点 → 输出其子树, 并停止向下重复搜索
static void HNPMSearchTree(UIView *v, NSMutableString *out, NSInteger *count) {
    @try {
        if (!v || *count > 140) return;
        if (HNPMInteresting(v)) {
            HNPMSubtree(v, out, 0, count);
            [out appendString:@"  ---[子树结束]---\n"];
            return;
        }
        for (UIView *s in [v subviews]) HNPMSearchTree(s, out, count);
    } @catch (NSException *e) {}
}

static void HNPMReconDump(NSString *reason) {
    @try {
        hnpmLastDump = CFAbsoluteTimeGetCurrent();
        NSMutableString *out = [NSMutableString stringWithFormat:@"[侦察] 原因=%@ 时间=%@\n", reason, [NSDate date]];
        NSArray *windows = [UIApplication sharedApplication].windows;
        [out appendFormat:@"[侦察] 窗口数=%lu\n", (unsigned long)windows.count];
        for (UIWindow *w in windows) {
            [out appendFormat:@"[窗口] %@ frame=%@ hidden=%d alpha=%.1f key=%d\n",
             NSStringFromClass([w class]), NSStringFromCGRect(w.frame),
             w.hidden ? 1 : 0, w.alpha, w.isKeyWindow ? 1 : 0];
        }
        for (UIWindow *w in windows) {
            if (w.hidden) continue;
            NSInteger count = 0;
            NSMutableString *tree = [NSMutableString stringWithFormat:@"[侦察] 窗口 %@ 命中:\n", NSStringFromClass([w class])];
            HNPMSearchTree(w, tree, &count);
            if (count > 0) [out appendString:tree];
        }
        HNPMAppendLog(out);
        HNPMAppendLog([NSString stringWithFormat:@"[侦察] 本轮完成(已侦察 %d/3 次)", hnpmDumpCount]);
    } @catch (NSException *e) {
        HNPMAppendLog(@"[侦察] 执行异常");
    }
}

#pragma mark - 播放状态轮询(驱动侦察)

static void HNPMCheckPlayback(void) {
    @try {
        if (!hnpmGetInfo) return;
        hnpmGetInfo(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(CFDictionaryRef info) {
            @try {
                BOOL hasInfo = (info != NULL && CFDictionaryGetCount(info) > 0);
                double rate = 0;
                if (hasInfo) {
                    CFNumberRef rateRef = CFDictionaryGetValue(info, CFSTR("kMRMediaRemoteNowPlayingInfoPlaybackRate"));
                    if (rateRef) CFNumberGetValue(rateRef, kCFNumberDoubleType, &rate);
                }
                BOOL playing = (hasInfo && rate > 0.05);
                dispatch_async(dispatch_get_main_queue(), ^{
                    @try {
                        // 检测到"开始播放"的跳变 → 3 秒后侦察一次(最多 3 次, 间隔 15 秒以上)
                        if (playing && !hnpmPrevPlaying && hnpmDumpCount < 3 &&
                            CFAbsoluteTimeGetCurrent() - hnpmLastDump > 15) {
                            hnpmDumpCount++;
                            HNPMAppendLog([NSString stringWithFormat:@"[侦察] 检测到开始播放(第 %d 次), 3 秒后侦察视图结构...", hnpmDumpCount]);
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                HNPMReconDump(@"开始播放");
                            });
                        }
                        hnpmPrevPlaying = playing;
                    } @catch (NSException *e) {}
                });
            } @catch (NSException *e) {}
        });
    } @catch (NSException *e) {}
}

#pragma mark - 类声明(供 logos 编译期使用)

@interface MRUNowPlayingViewController : UIViewController @end
@interface SBLockScreenNowPlayingController : NSObject @end
@interface MRUNowPlayingView : UIView @end
@interface MRUNowPlayingCellContentView : UIView @end
@interface MRUNowPlayingContainerView : UIView @end
@interface MRUAmbientNowPlayingView : UIView @end
@interface MRUAmbientCompactNowPlayingView : UIView @end

#pragma mark - hooks

// 控制中心模块(已确认身份, 保留时间线日志 + 视图登记, 下一版可能复用)
%group HNPMCardView
%hook MRUNowPlayingView
- (void)didMoveToWindow {
    %orig;
    @try {
        [hnpmCardViews addObject:self];
        HNPMLogThrottled([NSString stringWithFormat:@"[跟踪] MRUNowPlayingView 入窗口 frame=%@",
                          NSStringFromCGRect(self.frame)]);
    } @catch (NSException *e) {}
}
%end
%end

%group HNPMCellView
%hook MRUNowPlayingCellContentView
- (void)didMoveToWindow {
    %orig;
    @try {
        [hnpmCardViews addObject:self];
        HNPMLogThrottled([NSString stringWithFormat:@"[跟踪] MRUNowPlayingCellContentView 入窗口 frame=%@",
                          NSStringFromCGRect(self.frame)]);
    } @catch (NSException *e) {}
}
%end
%end

%group HNPMContainerView
%hook MRUNowPlayingContainerView
- (void)didMoveToWindow {
    %orig;
    @try {
        HNPMLogThrottled([NSString stringWithFormat:@"[跟踪] MRUNowPlayingContainerView 入窗口 frame=%@",
                          NSStringFromCGRect(self.frame)]);
    } @catch (NSException *e) {}
}
%end
%end

%group HNPMCard
%hook MRUNowPlayingViewController
- (void)viewDidLoad {
    %orig;
    @try { HNPMAppendLog(@"[跟踪] MRUNowPlayingViewController(控制中心模块) viewDidLoad"); } @catch (NSException *e) {}
}
%end
%end

// 灵动岛疑似视图(跟踪登记)
%group HNPMAmbientViewFull
%hook MRUAmbientNowPlayingView
- (void)didMoveToWindow {
    %orig;
    @try {
        [hnpmAmbientViews addObject:self];
        HNPMLogThrottled([NSString stringWithFormat:@"[跟踪] MRUAmbientNowPlayingView 入窗口 frame=%@",
                          NSStringFromCGRect(self.frame)]);
    } @catch (NSException *e) {}
}
%end
%end

%group HNPMAmbientViewCompact
%hook MRUAmbientCompactNowPlayingView
- (void)didMoveToWindow {
    %orig;
    @try {
        [hnpmAmbientViews addObject:self];
        HNPMLogThrottled([NSString stringWithFormat:@"[跟踪] MRUAmbientCompactNowPlayingView 入窗口 frame=%@",
                          NSStringFromCGRect(self.frame)]);
    } @catch (NSException *e) {}
}
%end
%end

// 一次性诊断: SBLockScreenNowPlayingController 成员变量
%group HNPMInspector
%hook SBLockScreenNowPlayingController
- (instancetype)init {
    id orig = %orig;
    @try {
        static BOOL dumped = NO;
        if (orig && !dumped) {
            dumped = YES;
            unsigned int count = 0;
            Class cls = object_getClass(orig);
            Ivar *ivars = class_copyIvarList(cls, &count);
            if (ivars) {
                NSMutableString *rep = [NSMutableString stringWithFormat:@"[诊断] %@ 成员变量(%u): ", NSStringFromClass(cls), count];
                for (unsigned int i = 0; i < count; i++) {
                    const char *type = ivar_getTypeEncoding(ivars[i]);
                    NSString *name = @(ivar_getName(ivars[i]));
                    [rep appendFormat:@"%@(%s)", name, type ? type : "?"];
                    if (type && type[0] == '@') {
                        id val = object_getIvar(orig, ivars[i]);
                        if (val && [val isKindOfClass:[NSObject class]]) {
                            [rep appendFormat:@"=<%@>", NSStringFromClass([val class])];
                        }
                    }
                    [rep appendString:@"; "];
                }
                free(ivars);
                HNPMAppendLog(rep);
            }
        }
    } @catch (NSException *e) {}
    return orig;
}
%end
%end

#pragma mark - 入口

__attribute__((constructor)) static void HNPMRawCtor(void) {
    HNPMAppendLog(@"v0.0.8: dylib 构造函数已执行(dyld 加载成功)");
}

%ctor {
    @autoreleasepool {
        HNPMAppendLog(@"v0.0.8: logos %ctor 进入");

        // 紧急开关
        if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/Documents/HideNowPlaying.off"]) {
            HNPMAppendLog(@"检测到开关文件 HideNowPlaying.off, 不注册任何 hook");
            return;
        }

        hnpmCardViews = [NSHashTable weakObjectsHashTable];
        hnpmAmbientViews = [NSHashTable weakObjectsHashTable];

        // MediaRemote 动态加载
        void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
        if (mr) {
            hnpmGetInfo = (HNPMGetInfoFunc)dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
            HNPMAppendLog([NSString stringWithFormat:@"MediaRemote 已加载, 播放检测%@", hnpmGetInfo ? @"可用" : @"不可用"]);
        } else {
            HNPMAppendLog(@"MediaRemote 加载失败");
        }

        // 播放状态轮询(1 秒), 驱动自动侦察
        if (hnpmGetInfo) {
            NSTimer *t = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
                HNPMCheckPlayback();
            }];
            [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
            hnpmTimer = t;
            HNPMAppendLog(@"播放状态轮询已启动(1s), 检测到开始播放将自动侦察视图结构");
        }

        // 按类存在性注册跟踪 hook
        if (objc_getClass("MRUNowPlayingView"))            { %init(HNPMCardView); }
        if (objc_getClass("MRUNowPlayingCellContentView")) { %init(HNPMCellView); }
        if (objc_getClass("MRUNowPlayingContainerView"))   { %init(HNPMContainerView); }
        if (objc_getClass("MRUNowPlayingViewController"))  { %init(HNPMCard); }
        if (objc_getClass("MRUAmbientNowPlayingView"))     { %init(HNPMAmbientViewFull); }
        if (objc_getClass("MRUAmbientCompactNowPlayingView")) { %init(HNPMAmbientViewCompact); }
        if (objc_getClass("SBLockScreenNowPlayingController")) { %init(HNPMInspector); }
        HNPMAppendLog(@"v0.0.8: %ctor 正常完成(hook 全部按需注册)");
    }
}
