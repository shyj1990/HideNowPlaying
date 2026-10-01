// HideNowPlaying v0.0.5 — 功能试验版
//
// 依据 v0.0.4 探针日志(iPhone 15 Pro / iOS 17.0 / relaxin)确认的真实类名:
//   锁屏播放卡片(推测宿主): MRUNowPlayingViewController
//   灵动岛播放器:           MRUAmbientNowPlayingViewController / MRUAmbientCompactNowPlayingViewController
//   锁屏正在播放控制器:      SBLockScreenNowPlayingController(只做一次性 ivar 诊断, 便于下版迭代)
//   (旧候选 SBDashBoardAggregatedMusicPlayerViewController 等在 iOS 17 上均不存在, 已弃用)
//
// 功能:
//   1. 锁屏播放卡片上左滑 → 隐藏卡片和灵动岛播放器(音乐不暂停)
//   2. 隐藏期间每 0.5s 检查播放速率: 出现"暂停(≥1秒)→继续播放"跳变 → 自动恢复显示
//   3. 安全措施: 只 hook 真实存在的类 / 全部逻辑 @try 包裹 / 只做视图级操作(不改系统布局逻辑)
//   4. 紧急开关: 存在 /var/mobile/Documents/HideNowPlaying.off 文件时不注册任何 hook
//
// 日志: /var/mobile/Documents/HideNowPlaying.log

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <math.h>
#import <stdlib.h>

#pragma mark - 前置声明

static void HNPMSetHidden(BOOL hide, NSString *reason);
static void HNPMStopPolling(void);

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

#pragma mark - 全局状态

static BOOL hnpmHidden = NO;                  // 当前是否处于"已隐藏"状态
static BOOL hnpmBaseline = NO;                // 是否完成隐藏后的第一次播放状态采样
static BOOL hnpmLastPlaying = NO;             // 上一次采样的播放状态
static int  hnpmPauseStreak = 0;              // 连续采样到"未在播放"的次数(防误判切歌瞬间)
static NSTimer *hnpmTimer = nil;              // 恢复检测定时器
static __weak UIView *hnpmCardView = nil;     // 锁屏播放卡片视图
static __weak UIView *hnpmAmbientView = nil;  // 灵动岛播放视图
static UIPanGestureRecognizer *hnpmPan = nil; // 左滑手势(全局只挂一个)

#pragma mark - MediaRemote(运行时 dlopen, 无需链接参数)

typedef void (*HNPMGetInfoFunc)(dispatch_queue_t, void (^)(CFDictionaryRef));
static HNPMGetInfoFunc hnpmGetInfo = NULL;

#pragma mark - 播放状态轮询(恢复检测)

static void HNPMCheckPlayback(void) {
    @try {
        if (!hnpmHidden || !hnpmGetInfo) { HNPMStopPolling(); return; }
        hnpmGetInfo(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(CFDictionaryRef info) {
            @try {
                if (!hnpmHidden) return;
                BOOL hasInfo = (info != NULL && CFDictionaryGetCount(info) > 0);
                BOOL playing = NO;
                if (hasInfo) {
                    CFNumberRef rateRef = CFDictionaryGetValue(info, CFSTR("kMRMediaRemoteNowPlayingInfoPlaybackRate"));
                    double rate = 0;
                    if (rateRef) CFNumberGetValue(rateRef, kCFNumberDoubleType, &rate);
                    playing = rate > 0.05;
                }
                if (!hnpmBaseline) {
                    // 隐藏后的第一次采样只记录基线, 不触发恢复
                    hnpmLastPlaying = playing;
                    hnpmPauseStreak = playing ? 0 : 1;
                    hnpmBaseline = YES;
                    return;
                }
                if (!playing) {
                    hnpmLastPlaying = NO;
                    hnpmPauseStreak++;
                    return;
                }
                // 从"连续≥2次未播放(≈1秒)"恢复到播放 → 判定为暂停后继续, 恢复显示
                if (!hnpmLastPlaying && hnpmPauseStreak >= 2) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        HNPMSetHidden(NO, @"检测到暂停后继续播放");
                    });
                }
                hnpmLastPlaying = YES;
                hnpmPauseStreak = 0;
            } @catch (NSException *e) {
                HNPMAppendLog([@"播放检测异常: " stringByAppendingString:e.description]);
            }
        });
    } @catch (NSException *e) {}
}

static void HNPMStartPolling(void) {
    if (hnpmTimer) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (hnpmTimer || !hnpmHidden) return;
        @try {
            NSTimer *t = [NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
                HNPMCheckPlayback();
            }];
            [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
            hnpmTimer = t;
            HNPMAppendLog(@"恢复检测定时器已启动(0.5s 轮询)");
        } @catch (NSException *e) {}
    });
}

static void HNPMStopPolling(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (hnpmTimer) { [hnpmTimer invalidate]; hnpmTimer = nil; }
        } @catch (NSException *e) {}
    });
}

#pragma mark - 隐藏 / 恢复

static void HNPMApplyHiddenToViews(BOOL hide) {
    @try {
        if (hnpmCardView) hnpmCardView.hidden = hide;
        if (hnpmAmbientView) hnpmAmbientView.hidden = hide;
    } @catch (NSException *e) {}
}

static void HNPMSetHidden(BOOL hide, NSString *reason) {
    if (hide == hnpmHidden) return;
    hnpmHidden = hide;
    hnpmBaseline = NO;
    hnpmPauseStreak = 0;
    if (hide) {
        HNPMStartPolling();
    } else {
        HNPMStopPolling();
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            HNPMApplyHiddenToViews(hide);
            HNPMAppendLog([NSString stringWithFormat:@"%@ → 状态=%@", reason, hide ? @"已隐藏(音乐继续)" : @"已恢复显示"]);
        } @catch (NSException *e) {}
    });
}

#pragma mark - 左滑手势 target(独立对象, 生命周期与进程相同)

@interface HNPMPanTarget : NSObject
@end

@implementation HNPMPanTarget
- (void)handlePan:(UIPanGestureRecognizer *)gr {
    @try {
        if (hnpmHidden) return;
        if (gr.state != UIGestureRecognizerStateChanged) return;
        CGPoint t = [gr translationInView:gr.view];
        // 左滑超过 60pt 且横向明显大于纵向 → 隐藏
        if (t.x < -60 && fabs(t.x) > fabs(t.y) * 1.5) {
            HNPMSetHidden(YES, @"锁屏播放卡片左滑");
        }
    } @catch (NSException *e) {}
}
@end

static HNPMPanTarget *hnpmPanTarget = nil;

#pragma mark - 类声明(供 logos 编译期使用)

@interface MRUNowPlayingViewController : UIViewController @end
@interface MRUAmbientNowPlayingViewController : UIViewController @end
@interface MRUAmbientCompactNowPlayingViewController : UIViewController @end
@interface SBLockScreenNowPlayingController : NSObject @end

#pragma mark - hooks

// 锁屏播放卡片: 挂左滑手势 + 隐藏期间保持隐藏
%group HNPMCard
%hook MRUNowPlayingViewController
- (void)viewDidLoad {
    %orig;
    @try {
        HNPMAppendLog([NSString stringWithFormat:@"[卡片] MRUNowPlayingViewController 出现 frame=%@",
                       NSStringFromCGRect(self.view.bounds)]);
    } @catch (NSException *e) {}
}
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    @try {
        hnpmCardView = self.view;
        if (!hnpmPan && hnpmPanTarget) {
            UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:hnpmPanTarget
                                                                                  action:@selector(handlePan:)];
            [self.view addGestureRecognizer:pan];
            hnpmPan = pan;
            HNPMAppendLog(@"[卡片] 左滑手势已挂载");
        }
        if (hnpmHidden) self.view.hidden = YES;
    } @catch (NSException *e) {}
}
- (void)viewDidLayoutSubviews {
    %orig;
    @try { if (hnpmHidden) self.view.hidden = YES; } @catch (NSException *e) {}
}
%end
%end

// 灵动岛播放器(完整版): 隐藏期间保持隐藏
%group HNPMAmbientFull
%hook MRUAmbientNowPlayingViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    @try {
        static BOOL logged = NO;
        if (!logged) { logged = YES; HNPMAppendLog(@"[灵动岛] MRUAmbientNowPlayingViewController 出现"); }
        hnpmAmbientView = self.view;
        if (hnpmHidden) self.view.hidden = YES;
    } @catch (NSException *e) {}
}
- (void)viewDidLayoutSubviews {
    %orig;
    @try { if (hnpmHidden) self.view.hidden = YES; } @catch (NSException *e) {}
}
%end
%end

// 灵动岛播放器(紧凑版): 隐藏期间保持隐藏
%group HNPMAmbientCompact
%hook MRUAmbientCompactNowPlayingViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    @try {
        static BOOL logged = NO;
        if (!logged) { logged = YES; HNPMAppendLog(@"[灵动岛] MRUAmbientCompactNowPlayingViewController 出现"); }
        hnpmAmbientView = self.view;
        if (hnpmHidden) self.view.hidden = YES;
    } @catch (NSException *e) {}
}
- (void)viewDidLayoutSubviews {
    %orig;
    @try { if (hnpmHidden) self.view.hidden = YES; } @catch (NSException *e) {}
}
%end
%end

// 一次性诊断: SBLockScreenNowPlayingController 的成员变量(若卡片不在上述类里, 从这里找线索)
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
    HNPMAppendLog(@"v0.0.5: dylib 构造函数已执行(dyld 加载成功)");
}

%ctor {
    @autoreleasepool {
        HNPMAppendLog(@"v0.0.5: logos %ctor 进入");

        // 紧急开关
        if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/Documents/HideNowPlaying.off"]) {
            HNPMAppendLog(@"检测到开关文件 HideNowPlaying.off, 不注册任何 hook");
            return;
        }

        // 左滑手势 target
        hnpmPanTarget = [[HNPMPanTarget alloc] init];

        // MediaRemote 动态加载(用于"暂停→继续"恢复检测)
        void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
        if (mr) {
            hnpmGetInfo = (HNPMGetInfoFunc)dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
            HNPMAppendLog([NSString stringWithFormat:@"MediaRemote 已加载, 播放速率检测%@", hnpmGetInfo ? @"可用" : @"不可用"]);
        } else {
            HNPMAppendLog(@"MediaRemote 加载失败, 暂停恢复功能不可用");
        }

        // 按"类真实存在"才注册 hook(全部类名来自 v0.0.4 探针在真机上的实测清单)
        if (objc_getClass("MRUNowPlayingViewController")) {
            %init(HNPMCard);
            HNPMAppendLog(@"hook 已注册: 锁屏播放卡片 MRUNowPlayingViewController");
        } else {
            HNPMAppendLog(@"跳过: MRUNowPlayingViewController 不存在");
        }
        if (objc_getClass("MRUAmbientNowPlayingViewController")) {
            %init(HNPMAmbientFull);
            HNPMAppendLog(@"hook 已注册: 灵动岛 MRUAmbientNowPlayingViewController");
        }
        if (objc_getClass("MRUAmbientCompactNowPlayingViewController")) {
            %init(HNPMAmbientCompact);
            HNPMAppendLog(@"hook 已注册: 灵动岛 MRUAmbientCompactNowPlayingViewController");
        }
        if (objc_getClass("SBLockScreenNowPlayingController")) {
            %init(HNPMInspector);
            HNPMAppendLog(@"hook 已注册: 诊断 SBLockScreenNowPlayingController");
        }

        HNPMAppendLog(@"v0.0.5: %ctor 正常完成");
    }
}
