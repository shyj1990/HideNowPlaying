// HideNowPlaying v0.0.10 — 深度侦察 + 卡片单元格手势尝试
//
// v0.0.9 侦察结论(iPhone 15 Pro / iOS 17.0 / relaxin):
//   ✅ 锁屏+播放时 SBCoverSheetWindow(key=1) 的内容在 CSCoverSheetView → CSScrollView
//      (分页滚动视图, 挂着 UIScrollViewPagingSwipeGestureRecognizer) → 播放卡片是其中的 Cell
//   ❌ 全量树深度 6 截断在 CSScrollView, 没拍到卡片内部
//   ❌ 灵动岛窗口(SBSystemApertureWindow x2)无关键词命中, 内容类名未知
//   ⚠ 侦察调度未在计划时更新 lastDump, 导致同秒重复侦察(已修)
//
// v0.0.10:
//   A. 侦察: 锁屏窗口深度 12/上限 500 节点; 灵动岛窗口全量(深度 8/200); 调度时即更新 lastDump
//   B. 功能尝试: 对 MRUNowPlayingCellContentView(卡片单元格内容, 强嫌疑)挂左滑手势
//      (手势代理抢占优先级), 隐藏对象 = 卡片视图 + 灵动岛视图; 暂停≥1秒→继续播放 恢复
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
static void HNPMLogThrottled(NSString *text);
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
    } @catch (NSException *exception) {}
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

static BOOL hnpmHidden = NO;                  // 当前是否处于"已隐藏"状态
static BOOL hnpmBaseline = NO;                // 隐藏后是否完成首次播放采样
static BOOL hnpmLastPlaying = NO;             // 上次采样播放状态
static int  hnpmPauseStreak = 0;              // 连续"未播放"采样次数
static NSTimer *hnpmTimer = nil;              // 1 秒轮询定时器
static int hnpmDumpCount = 0;                 // 已侦察次数(最多 4)
static CFAbsoluteTime hnpmLastDump = 0;       // 上次"计划"侦察时间
static NSHashTable *hnpmCardViews = nil;      // 弱引用表: 卡片视图
static NSHashTable *hnpmAmbientViews = nil;   // 弱引用表: 灵动岛视图
static void *kHNPMPanKey = &kHNPMPanKey;      // 关联对象 key: 已挂手势标记

#pragma mark - MediaRemote(运行时 dlopen)

typedef void (*HNPMGetInfoFunc)(dispatch_queue_t, void (^)(CFDictionaryRef));
static HNPMGetInfoFunc hnpmGetInfo = NULL;

#pragma mark - 隐藏 / 恢复

static void HNPMApplyHiddenToViews(BOOL hide) {
    @try {
        for (UIView *v in hnpmCardViews)   { v.hidden = hide; }
        for (UIView *v in hnpmAmbientViews){ v.hidden = hide; }
    } @catch (NSException *e) {}
}

static void HNPMSetHidden(BOOL hide, NSString *reason) {
    if (hide == hnpmHidden) return;
    hnpmHidden = hide;
    hnpmBaseline = NO;
    hnpmPauseStreak = 0;
    if (hide) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (hnpmTimer) return;
            @try {
                NSTimer *t = [NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
                    // 恢复检测在 HNPMCheckPlayback 里由 hnpmHidden 分支处理
                }];
                [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
                hnpmTimer = t;
            } @catch (NSException *e) {}
        });
    } else {
        HNPMStopPolling();
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            HNPMApplyHiddenToViews(hide);
            HNPMAppendLog([NSString stringWithFormat:@"%@ → 状态=%@ (卡片%lu个/灵动岛%lu个)",
                           reason, hide ? @"已隐藏(音乐继续)" : @"已恢复显示",
                           (unsigned long)hnpmCardViews.count, (unsigned long)hnpmAmbientViews.count]);
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

#pragma mark - 左滑手势 target + 代理

@interface HNPMPanTarget : NSObject <UIGestureRecognizerDelegate>
@end

@implementation HNPMPanTarget

- (void)handlePan:(UIPanGestureRecognizer *)gr {
    @try {
        if (hnpmHidden) return;
        CGPoint t = [gr translationInView:gr.view];
        CGPoint v = [gr velocityInView:gr.view];
        if (gr.state == UIGestureRecognizerStateChanged) {
            HNPMLogThrottled([NSString stringWithFormat:@"[手势] 移动中 t=(%.0f,%.0f) v=(%.0f,%.0f)", t.x, t.y, v.x, v.y]);
            if (t.x < -60 && fabs(t.x) > fabs(t.y) * 1.5) {
                HNPMSetHidden(YES, @"锁屏播放卡片左滑");
            }
        } else if (gr.state == UIGestureRecognizerStateEnded) {
            if (t.x < -55 && fabs(t.x) > fabs(t.y) * 1.2 && v.x < -300) {
                HNPMSetHidden(YES, @"锁屏播放卡片左滑(轻扫)");
            }
        }
    } @catch (NSException *e) {}
}

// 只有"向左拖"的意图才开始, 其它方向立即放弃, 把触摸还给系统
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gr {
    @try {
        if (![gr isKindOfClass:[UIPanGestureRecognizer class]]) return NO;
        UIPanGestureRecognizer *p = (UIPanGestureRecognizer *)gr;
        CGPoint t = [p translationInView:p.view];
        CGPoint v = [p velocityInView:p.view];
        BOOL left = (t.x < 0 || v.x < -100) && fabs(t.x) > fabs(t.y);
        HNPMLogThrottled([NSString stringWithFormat:@"[手势] shouldBegin t=(%.0f,%.0f) v=(%.0f,%.0f) → %@", t.x, t.y, v.x, v.y, left ? @"YES" : @"NO"]);
        return left;
    } @catch (NSException *e) { return NO; }
}

// 卡片内部的其它手势(按钮等)不受影响; 对外层手势(分页滚动等)我们优先
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gr shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {
    @try {
        UIView *otherView = other.view;
        UIView *card = gr.view;
        if (!otherView || !card) return NO;
        return ![otherView isDescendantOfView:card];
    } @catch (NSException *e) { return NO; }
}

@end

static HNPMPanTarget *hnpmPanTarget = nil;

static void HNPMAttachPanIfNeeded(UIView *view) {
    @try {
        if (!hnpmPanTarget || !view || !view.window) return;
        if (objc_getAssociatedObject(view, kHNPMPanKey)) return;
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:hnpmPanTarget
                                                                              action:@selector(handlePan:)];
        pan.delegate = hnpmPanTarget;
        pan.maximumNumberOfTouches = 1;
        objc_setAssociatedObject(view, kHNPMPanKey, pan, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [view addGestureRecognizer:pan];
        HNPMAppendLog([NSString stringWithFormat:@"[手势] 已挂到 %@ frame=%@",
                       NSStringFromClass([view class]), NSStringFromCGRect(view.frame)]);
    } @catch (NSException *e) {}
}

#pragma mark - 视图树侦察

static void HNPMSubtree(UIView *v, NSMutableString *out, NSInteger depth, NSInteger *count, NSInteger cap, NSInteger maxDepth) {
    @try {
        if (!v || *count > cap || depth > maxDepth) return;
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
        for (UIView *s in [v subviews]) HNPMSubtree(s, out, depth + 1, count, cap, maxDepth);
    } @catch (NSException *e) {}
}

static BOOL HNPMInteresting(UIView *v) {
    @try {
        if (!v || v.hidden || v.alpha < 0.05) return NO;
        if (v.frame.size.width < 40 || v.frame.size.height < 40) return NO;
        NSString *n = NSStringFromClass([v class]);
        return ([n containsString:@"Media"] || [n containsString:@"NowPlaying"] ||
                [n containsString:@"Controls"] || [n containsString:@"Player"] ||
                [n containsString:@"Ambient"] || [n containsString:@"Backdrop"] ||
                [n containsString:@"DashBoard"] || [n containsString:@"Island"] ||
                [n containsString:@"MPU"] || [n containsString:@"Music"]);
    } @catch (NSException *e) { return NO; }
}

static void HNPMSearchTree(UIView *v, NSMutableString *out, NSInteger *count) {
    @try {
        if (!v || *count > 300) return;
        if (HNPMInteresting(v)) {
            UIView *root = v;
            for (int i = 0; i < 3 && root.superview; i++) root = root.superview;
            HNPMSubtree(root, out, 0, count, 150, 8);
            [out appendString:@"  ---[周边子树结束]---\n"];
            return;
        }
        for (UIView *s in [v subviews]) HNPMSearchTree(s, out, count);
    } @catch (NSException *e) {}
}

static void HNPMReconDump(NSString *reason) {
    @try {
        NSMutableString *out = [NSMutableString stringWithFormat:@"[侦察] 原因=%@ 时间=%@\n", reason, [NSDate date]];
        NSArray *windows = [UIApplication sharedApplication].windows;
        for (UIWindow *w in windows) {
            [out appendFormat:@"[窗口] %@ frame=%@ hidden=%d alpha=%.1f key=%d\n",
             NSStringFromClass([w class]), NSStringFromCGRect(w.frame),
             w.hidden ? 1 : 0, w.alpha, w.isKeyWindow ? 1 : 0];
        }
        for (UIWindow *w in windows) {
            if (w.hidden) continue;
            NSString *wc = NSStringFromClass([w class]);
            NSInteger count = 0;
            if ([wc containsString:@"CoverSheet"]) {
                // 锁屏窗口: 深度全量扫描
                NSMutableString *tree = [NSMutableString stringWithFormat:@"[侦察] 锁屏窗口 %@ 全量树(深度12):\n", wc];
                HNPMSubtree(w, tree, 0, &count, 500, 12);
                [out appendString:tree];
            } else if ([wc containsString:@"Aperture"]) {
                // 灵动岛窗口: 全量扫描
                NSMutableString *tree = [NSMutableString stringWithFormat:@"[侦察] 灵动岛窗口 %@ 全量树:\n", wc];
                HNPMSubtree(w, tree, 0, &count, 200, 8);
                [out appendString:tree];
            } else {
                NSMutableString *tree = [NSMutableString stringWithFormat:@"[侦察] 窗口 %@ 命中:\n", wc];
                HNPMSearchTree(w, tree, &count);
                if (count > 0) [out appendString:tree];
            }
        }
        HNPMAppendLog(out);
        HNPMAppendLog([NSString stringWithFormat:@"[侦察] 本轮完成(已侦察 %d/4 次)", hnpmDumpCount]);
    } @catch (NSException *e) {
        HNPMAppendLog(@"[侦察] 执行异常");
    }
}

#pragma mark - 播放状态轮询(侦察调度 + 隐藏后恢复检测)

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
                        if (hnpmHidden) {
                            // 恢复检测: 从"连续≥1秒未播放"恢复播放 → 恢复显示
                            if (!hnpmBaseline) {
                                hnpmLastPlaying = playing;
                                hnpmPauseStreak = playing ? 0 : 1;
                                hnpmBaseline = YES;
                            } else if (!playing) {
                                hnpmLastPlaying = NO;
                                hnpmPauseStreak++;
                            } else {
                                if (!hnpmLastPlaying && hnpmPauseStreak >= 2) {
                                    HNPMSetHidden(NO, @"检测到暂停后继续播放");
                                }
                                hnpmLastPlaying = YES;
                                hnpmPauseStreak = 0;
                            }
                            return;
                        }
                        // 侦察调度: 播放中每 12 秒一次(最多 4 次), lastDump 在计划时更新
                        if (playing && hnpmDumpCount < 4 &&
                            CFAbsoluteTimeGetCurrent() - hnpmLastDump > 12) {
                            hnpmDumpCount++;
                            hnpmLastDump = CFAbsoluteTimeGetCurrent();
                            BOOL first = (hnpmDumpCount == 1);
                            NSTimeInterval delay = first ? 2.0 : 0.0;
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                HNPMReconDump(first ? @"开始播放" : @"播放中持续侦察");
                            });
                        }
                    } @catch (NSException *e) {}
                });
            } @catch (NSException *e) {}
        });
    } @catch (NSException *e) {}
}

#pragma mark - 类声明

@interface MRUNowPlayingViewController : UIViewController @end
@interface SBLockScreenNowPlayingController : NSObject @end
@interface MRUNowPlayingView : UIView @end
@interface MRUNowPlayingCellContentView : UIView @end
@interface MRUAmbientNowPlayingView : UIView @end
@interface MRUAmbientCompactNowPlayingView : UIView @end

#pragma mark - hooks

// 卡片单元格内容(强嫌疑): 登记 + 挂手势 + 隐藏期间保持
%group HNPMCellView
%hook MRUNowPlayingCellContentView
- (void)didMoveToWindow {
    %orig;
    @try {
        [hnpmCardViews addObject:self];
        if (!self.userInteractionEnabled) {
            self.userInteractionEnabled = YES;
            HNPMAppendLog(@"[卡片] MRUNowPlayingCellContentView 原本 userInteractionEnabled=NO, 已改为 YES");
        }
        HNPMAttachPanIfNeeded(self);
        HNPMLogThrottled([NSString stringWithFormat:@"[卡片] MRUNowPlayingCellContentView 入窗口 frame=%@ superview=%@",
                          NSStringFromCGRect(self.frame),
                          self.superview ? NSStringFromClass([self.superview class]) : @"(无)"]);
        if (hnpmHidden) self.hidden = YES;
    } @catch (NSException *e) {}
}
%end
%end

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

%group HNPMAmbientViewFull
%hook MRUAmbientNowPlayingView
- (void)didMoveToWindow {
    %orig;
    @try {
        [hnpmAmbientViews addObject:self];
        HNPMLogThrottled([NSString stringWithFormat:@"[跟踪] MRUAmbientNowPlayingView 入窗口 frame=%@",
                          NSStringFromCGRect(self.frame)]);
        if (hnpmHidden) self.hidden = YES;
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
        if (hnpmHidden) self.hidden = YES;
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
    HNPMAppendLog(@"v0.0.10: dylib 构造函数已执行(dyld 加载成功)");
}

%ctor {
    @autoreleasepool {
        HNPMAppendLog(@"v0.0.10: logos %ctor 进入");

        if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/Documents/HideNowPlaying.off"]) {
            HNPMAppendLog(@"检测到开关文件 HideNowPlaying.off, 不注册任何 hook");
            return;
        }

        hnpmCardViews = [NSHashTable weakObjectsHashTable];
        hnpmAmbientViews = [NSHashTable weakObjectsHashTable];
        hnpmPanTarget = [[HNPMPanTarget alloc] init];

        void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
        if (mr) {
            hnpmGetInfo = (HNPMGetInfoFunc)dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
            HNPMAppendLog([NSString stringWithFormat:@"MediaRemote 已加载, 播放检测%@", hnpmGetInfo ? @"可用" : @"不可用"]);
        } else {
            HNPMAppendLog(@"MediaRemote 加载失败");
        }

        if (hnpmGetInfo) {
            NSTimer *t = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
                HNPMCheckPlayback();
            }];
            [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
            hnpmTimer = t;
            HNPMAppendLog(@"播放状态轮询已启动(1s)");
        }

        if (objc_getClass("MRUNowPlayingCellContentView")) { %init(HNPMCellView); HNPMAppendLog(@"hook 已注册: 卡片单元格 MRUNowPlayingCellContentView(手势挂载)"); }
        if (objc_getClass("MRUNowPlayingView"))            { %init(HNPMCardView); }
        if (objc_getClass("MRUAmbientNowPlayingView"))     { %init(HNPMAmbientViewFull); }
        if (objc_getClass("MRUAmbientCompactNowPlayingView")) { %init(HNPMAmbientViewCompact); }
        if (objc_getClass("MRUNowPlayingViewController"))  { %init(HNPMCard); }
        if (objc_getClass("SBLockScreenNowPlayingController")) { %init(HNPMInspector); }
        HNPMAppendLog(@"v0.0.10: %ctor 正常完成(hook 全部按需注册)");
    }
}
