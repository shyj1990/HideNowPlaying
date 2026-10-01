// HideNowPlaying v0.0.12 — 功能版(基于侦察确认的真实结构)
//
// v0.0.11 侦察结论(iPhone 15 Pro / iOS 17.0 / relaxin):
//   锁屏播放卡片 = 通知列表里的一个单元格:
//     NCNotificationListCell(365x167, 自带 UIPanGestureRecognizer)
//       └ NCNotificationListSupplementaryHostingView(GR<Tap>)
//         └ PLPlatterView(毛玻璃底板)
//           └ CSActivityItemContentView  ← 媒体实况活动内容(远程渲染 _UIScenePresentationView)
//   灵动岛 = SBSystemApertureContainerView
//     └ ScalingContentView → RotatingContentView → SAUIElementView
//       ├ _SAUIElementViewContentView(锁图标 SBUIProudLockIconView + 媒体图标 37x37)
//       └ _SAUIProvidedViewContainerView x3 → _SAUIPortalView(媒体内容为远程门户渲染)
//
// v0.0.12 功能实现:
//   1. hook CSActivityItemContentView 入窗口 → 上溯找到所属 NCNotificationListCell
//      → 登记为媒体卡片 + 挂左滑手势(代理抢占优先级)
//   2. 左滑 → 隐藏卡片单元格 + 灵动岛媒体内容(_SAUIElementViewContentView + 宽>=30 的门户)
//   3. 暂停≥1秒 → 继续播放 → 恢复显示(播放速率轮询)
//   4. 隐藏期间新出现的卡片/灵动岛内容自动保持隐藏
//
// 日志: /var/mobile/Documents/HideNowPlaying.log   紧急开关: /var/mobile/Documents/HideNowPlaying.off

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <math.h>
#import <stdlib.h>

#pragma mark - 前置声明

static void HNPMSetHidden(BOOL hide, NSString *reason);
static void HNPMLogThrottled(NSString *text);

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

static BOOL hnpmHidden = NO;                  // 当前是否已隐藏
static BOOL hnpmBaseline = NO;                // 隐藏后是否完成首次播放采样
static BOOL hnpmLastPlaying = NO;             // 上次采样播放状态
static int  hnpmPauseStreak = 0;              // 连续"未播放"采样次数(0.5s 每次)
static NSHashTable *hnpmCardViews = nil;      // 弱引用: 卡片单元格 + 内容视图
static NSHashTable *hnpmIslandViews = nil;    // 弱引用: 灵动岛媒体相关视图
static void *kHNPMPanKey = &kHNPMPanKey;      // 关联对象: 已挂手势标记

#pragma mark - MediaRemote(运行时 dlopen, 无需链接参数)

typedef void (*HNPMGetInfoFunc)(dispatch_queue_t, void (^)(CFDictionaryRef));
static HNPMGetInfoFunc hnpmGetInfo = NULL;

#pragma mark - 隐藏 / 恢复

static void HNPMApplyHiddenToViews(BOOL hide) {
    @try {
        for (UIView *v in hnpmCardViews)  { v.hidden = hide; }
        for (UIView *v in hnpmIslandViews) {
            // 门户只隐藏媒体尺寸(>=30)的; 元素内容视图全部隐藏
            if ([NSStringFromClass([v class]) containsString:@"ProvidedViewContainer"] &&
                v.frame.size.width < 30 && v.frame.size.height < 30) continue;
            v.hidden = hide;
        }
    } @catch (NSException *e) {}
}

static void HNPMSetHidden(BOOL hide, NSString *reason) {
    if (hide == hnpmHidden) return;
    hnpmHidden = hide;
    hnpmBaseline = NO;
    hnpmPauseStreak = 0;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            HNPMApplyHiddenToViews(hide);
            HNPMAppendLog([NSString stringWithFormat:@"%@ → 状态=%@ (卡片%lu个/灵动岛%lu个)",
                           reason, hide ? @"已隐藏(音乐继续)" : @"已恢复显示",
                           (unsigned long)hnpmCardViews.count, (unsigned long)hnpmIslandViews.count]);
        } @catch (NSException *e) {}
    });
}

// 0.5 秒轮询: 隐藏期间检测"暂停→继续播放"以恢复显示
static void HNPMStartRestorePolling(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            static NSTimer *restoreTimer = nil;
            if (restoreTimer) return;
            restoreTimer = [NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
                @try {
                    if (!hnpmHidden) {
                        [timer invalidate];
                        restoreTimer = nil;
                        return;
                    }
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
                                    if (!hnpmHidden) return;
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
                                } @catch (NSException *e) {}
                            });
                        } @catch (NSException *e) {}
                    });
                } @catch (NSException *e) {}
            }];
            [[NSRunLoop mainRunLoop] addTimer:restoreTimer forMode:NSRunLoopCommonModes];
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
                HNPMStartRestorePolling();
            }
        } else if (gr.state == UIGestureRecognizerStateEnded) {
            if (t.x < -55 && fabs(t.x) > fabs(t.y) * 1.2 && v.x < -300) {
                HNPMSetHidden(YES, @"锁屏播放卡片左滑(轻扫)");
                HNPMStartRestorePolling();
            }
        }
    } @catch (NSException *e) {}
}

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

// 我们的手势优先: 其它所有手势(通知清除/列表滚动)等我们先判定
// (shouldBegin 对非左滑立即返回 NO, 不影响正常交互)
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gr shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
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

#pragma mark - 媒体卡片识别

// 从 CSActivityItemContentView 上溯找所属的通知单元格
static UIView *HNPMFindCellAncestor(UIView *v) {
    @try {
        Class cellClass = NSClassFromString(@"NCNotificationListCell");
        if (!cellClass) return nil;
        UIView *p = v;
        while (p && ![p isKindOfClass:cellClass]) p = p.superview;
        return p;
    } @catch (NSException *e) { return nil; }
}

#pragma mark - 类声明(logos 编译期)

@interface CSActivityItemContentView : UIView @end
@interface _SAUIProvidedViewContainerView : UIView @end
@interface _SAUIElementViewContentView : UIView @end
@interface NCNotificationListCell : UIView @end

#pragma mark - hooks

// 媒体卡片内容(实况活动)出现 → 找到单元格 → 登记 + 挂手势
%group HNPMActivityCard
%hook CSActivityItemContentView
- (void)didMoveToWindow {
    %orig;
    @try {
        if (!self.window) return;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            @try {
                if (!self.window) return;
                UIView *cell = HNPMFindCellAncestor(self);
                if (!cell) {
                    HNPMLogThrottled(@"[卡片] CSActivityItemContentView 不在通知单元格内(可能是其他实况活动)");
                    return;
                }
                [hnpmCardViews addObject:self];
                [hnpmCardViews addObject:cell];
                HNPMAttachPanIfNeeded(cell);
                HNPMLogThrottled([NSString stringWithFormat:@"[卡片] 媒体卡片已登记 单元格=%@ 内容=%@",
                                  NSStringFromCGRect(cell.frame), NSStringFromCGRect(self.frame)]);
                if (hnpmHidden) {
                    self.hidden = YES;
                    cell.hidden = YES;
                }
            } @catch (NSException *e) {}
        });
    } @catch (NSException *e) {}
}
%end
%end

// 灵动岛: 元素内容视图(锁图标+媒体图标)
%group HNPMIslandElement
%hook _SAUIElementViewContentView
- (void)didMoveToWindow {
    %orig;
    @try {
        if (!self.window) return;
        [hnpmIslandViews addObject:self];
        HNPMLogThrottled([NSString stringWithFormat:@"[灵动岛] 元素内容视图登记 frame=%@",
                          NSStringFromCGRect(self.frame)]);
        if (hnpmHidden) self.hidden = YES;
    } @catch (NSException *e) {}
}
%end
%end

// 灵动岛: 门户容器(媒体内容远程渲染, 媒体的宽约 37)
%group HNPMIslandPortal
%hook _SAUIProvidedViewContainerView
- (void)didMoveToWindow {
    %orig;
    @try {
        if (!self.window) return;
        [hnpmIslandViews addObject:self];
        HNPMLogThrottled([NSString stringWithFormat:@"[灵动岛] 门户登记 frame=%@",
                          NSStringFromCGRect(self.frame)]);
        if (hnpmHidden) self.hidden = YES;
    } @catch (NSException *e) {}
}
%end
%end

#pragma mark - 入口

__attribute__((constructor)) static void HNPMRawCtor(void) {
    HNPMAppendLog(@"v0.0.12: dylib 构造函数已执行(dyld 加载成功)");
}

%ctor {
    @autoreleasepool {
        HNPMAppendLog(@"v0.0.12: logos %ctor 进入");

        if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/Documents/HideNowPlaying.off"]) {
            HNPMAppendLog(@"检测到开关文件 HideNowPlaying.off, 不注册任何 hook");
            return;
        }

        hnpmCardViews = [NSHashTable weakObjectsHashTable];
        hnpmIslandViews = [NSHashTable weakObjectsHashTable];
        hnpmPanTarget = [[HNPMPanTarget alloc] init];

        void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
        if (mr) {
            hnpmGetInfo = (HNPMGetInfoFunc)dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
            HNPMAppendLog([NSString stringWithFormat:@"MediaRemote 已加载, 播放检测%@", hnpmGetInfo ? @"可用" : @"不可用"]);
        } else {
            HNPMAppendLog(@"MediaRemote 加载失败");
        }

        if (objc_getClass("CSActivityItemContentView"))       { %init(HNPMActivityCard); HNPMAppendLog(@"hook 已注册: 媒体卡片 CSActivityItemContentView"); }
        if (objc_getClass("_SAUIElementViewContentView"))     { %init(HNPMIslandElement); HNPMAppendLog(@"hook 已注册: 灵动岛元素内容"); }
        if (objc_getClass("_SAUIProvidedViewContainerView"))  { %init(HNPMIslandPortal); HNPMAppendLog(@"hook 已注册: 灵动岛门户"); }
        HNPMAppendLog(@"v0.0.12: %ctor 正常完成(功能版, 左滑隐藏 / 暂停再播恢复)");
    }
}
