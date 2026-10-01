// HideNowPlaying v0.0.13 — 精修版(动画 + 恢复修复 + 通知误伤修复)
//
// v0.0.12 用户反馈:
//   ✅ 左滑隐藏卡片(音乐继续) / 暂停→播放恢复卡片 均正常
//   ❌ 灵动岛隐藏后, 暂停→播放没有恢复 → 修复: 恢复时全量扫描所有窗口,
//      强制恢复所有通知单元格/灵动岛视图的显示(补漏二次修复)
//   ❌ 其他 app 的通知也消失了 → 修复: 根因是普通通知内容也用 CSActivityItemContentView,
//      之前全部登记隐藏; 现在只认尺寸 >=300x140 的媒体卡片
//   ✅ 隐藏灵动岛内容正是想要的, 保留
//   ➕ 新增: 左滑"向左滑出屏幕"动画, 恢复时淡入
//
// 结构(iPhone 15 Pro / iOS 17.0 / relaxin 实测):
//   锁屏卡片 = NCNotificationListCell(365x167) → PLPlatterView → CSActivityItemContentView(远程渲染)
//   灵动岛   = SAUIElementView → _SAUIElementViewContentView + _SAUIProvidedViewContainerView(门户)
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
static void HNPMStartRestorePolling(void);
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

static BOOL hnpmHidden = NO;
static BOOL hnpmBaseline = NO;
static BOOL hnpmLastPlaying = NO;
static int  hnpmPauseStreak = 0;
static NSHashTable *hnpmCardViews = nil;      // 弱引用: 媒体卡片(单元格+内容)
static NSHashTable *hnpmIslandViews = nil;    // 弱引用: 灵动岛媒体相关视图
static void *kHNPMPanKey = &kHNPMPanKey;

#pragma mark - MediaRemote

typedef void (*HNPMGetInfoFunc)(dispatch_queue_t, void (^)(CFDictionaryRef));
static HNPMGetInfoFunc hnpmGetInfo = NULL;

#pragma mark - 媒体卡片判定

// 只有媒体实况卡片才有这个尺寸(实测 365x167); 普通通知更矮, 严格过滤防误伤
static BOOL HNPMIsMediaSized(CGSize size) {
    return size.width >= 300 && size.height >= 140;
}

#pragma mark - 隐藏 / 恢复(带动画)

// 卡片滑出/滑入
static void HNPMAnimateCard(UIView *cell, BOOL hide) {
    @try {
        if (hide) {
            [UIView animateWithDuration:0.35
                                  delay:0.0
                                options:UIViewAnimationOptionCurveEaseIn
                             animations:^{
                cell.transform = CGAffineTransformTranslate(CGAffineTransformIdentity, -440, 0);
                cell.alpha = 0.0;
            }
                             completion:^(BOOL finished) {
                @try {
                    if (hnpmHidden) {
                        cell.hidden = YES;
                        cell.transform = CGAffineTransformIdentity;
                        cell.alpha = 1.0;
                    }
                } @catch (NSException *e) {}
            }];
        } else {
            cell.transform = CGAffineTransformTranslate(CGAffineTransformIdentity, -440, 0);
            cell.alpha = 0.0;
            cell.hidden = NO;
            [UIView animateWithDuration:0.35
                                  delay:0.0
                                options:UIViewAnimationOptionCurveEaseOut
                             animations:^{
                cell.transform = CGAffineTransformIdentity;
                cell.alpha = 1.0;
            }
                             completion:nil];
        }
    } @catch (NSException *e) {
        cell.hidden = hide;
    }
}

// 灵动岛内容淡出/淡入
static void HNPMAnimateIsland(UIView *v, BOOL hide) {
    @try {
        if (hide) {
            [UIView animateWithDuration:0.25 animations:^{ v.alpha = 0.0; }
                             completion:^(BOOL finished) {
                @try {
                    if (hnpmHidden) v.hidden = YES;
                    v.alpha = 1.0;
                } @catch (NSException *e) {}
            }];
        } else {
            v.hidden = NO;
            v.alpha = 0.0;
            [UIView animateWithDuration:0.25 animations:^{ v.alpha = 1.0; }
                             completion:nil];
        }
    } @catch (NSException *e) {
        v.hidden = hide;
    }
}

static void HNPMApplyHiddenAnimated(BOOL hide) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            for (UIView *v in hnpmCardViews) {
                if ([NSStringFromClass([v class]) containsString:@"Cell"]) {
                    HNPMAnimateCard(v, hide);          // 单元格: 滑出/滑入
                } else {
                    HNPMAnimateIsland(v, hide);        // 卡片内容视图: 淡出/淡入
                }
            }
            for (UIView *v in hnpmIslandViews) {
                // 门户只处理媒体尺寸(>=30)的
                if ([NSStringFromClass([v class]) containsString:@"ProvidedViewContainer"] &&
                    v.frame.size.width < 30 && v.frame.size.height < 30) continue;
                HNPMAnimateIsland(v, hide);
            }
        } @catch (NSException *e) {}
    });
}

// 全量修复: 扫描所有窗口, 把我们可能隐藏过的视图强制恢复显示
// (解决"灵动岛/通知恢复失败": 视图复用或重建导致弱引用失效的情况)
static void HNPMFullHeal(NSString *reason) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            int healed = 0;
            for (UIWindow *w in [UIApplication sharedApplication].windows) {
                NSMutableArray *stack = [NSMutableArray arrayWithObject:w];
                while (stack.count > 0 && healed < 400) {
                    UIView *v = stack.firstObject;
                    [stack removeObjectAtIndex:0];
                    if (!v) continue;
                    NSString *n = NSStringFromClass([v class]);
                    if ([n isEqualToString:@"NCNotificationListCell"] ||
                        [n isEqualToString:@"_SAUIElementViewContentView"] ||
                        [n isEqualToString:@"_SAUIProvidedViewContainerView"]) {
                        if (v.hidden) { v.hidden = NO; healed++; }
                        if ([n isEqualToString:@"NCNotificationListCell"]) {
                            if (!CGAffineTransformIsIdentity(v.transform)) v.transform = CGAffineTransformIdentity;
                            if (v.alpha < 1.0) v.alpha = 1.0;
                        }
                    }
                    [stack addObjectsFromArray:[v subviews]];
                }
            }
            if (healed > 0) HNPMAppendLog([NSString stringWithFormat:@"[修复] %@ 强制恢复 %d 个视图", reason, healed]);
        } @catch (NSException *e) {}
    });
}

static void HNPMSetHidden(BOOL hide, NSString *reason) {
    if (hide == hnpmHidden) return;
    hnpmHidden = hide;
    hnpmBaseline = NO;
    hnpmPauseStreak = 0;
    if (hide) {
        HNPMApplyHiddenAnimated(YES);
    } else {
        HNPMApplyHiddenAnimated(NO);
        HNPMFullHeal(@"恢复显示");
        // 二次补漏: 1 秒后再修复一次(覆盖恢复瞬间重建的视图)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!hnpmHidden) HNPMFullHeal(@"恢复补漏");
        });
    }
    HNPMAppendLog([NSString stringWithFormat:@"%@ → 状态=%@",
                   reason, hide ? @"已隐藏(音乐继续)" : @"已恢复显示"]);
}

// 0.5 秒轮询: 隐藏期间检测"暂停→继续播放"
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
        return (t.x < 0 || v.x < -100) && fabs(t.x) > fabs(t.y);
    } @catch (NSException *e) { return NO; }
}

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

#pragma mark - 类声明

@interface CSActivityItemContentView : UIView @end
@interface _SAUIProvidedViewContainerView : UIView @end
@interface _SAUIElementViewContentView : UIView @end
@interface NCNotificationListCell : UIView @end

#pragma mark - hooks

// 媒体卡片内容出现 → 上溯找单元格 → 尺寸过滤 → 登记 + 挂手势
%group HNPMActivityCard
%hook CSActivityItemContentView
- (void)didMoveToWindow {
    %orig;
    @try {
        if (!self.window) return;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            @try {
                if (!self.window) return;
                if (!HNPMIsMediaSized(self.frame.size)) return;   // 非媒体尺寸: 不碰(普通通知保护)
                Class cellClass = NSClassFromString(@"NCNotificationListCell");
                UIView *p = self;
                while (p && ![p isKindOfClass:cellClass]) p = p.superview;
                if (!p) return;
                UIView *cell = p;
                [hnpmCardViews addObject:self];
                [hnpmCardViews addObject:cell];
                HNPMAttachPanIfNeeded(cell);
                HNPMLogThrottled([NSString stringWithFormat:@"[卡片] 媒体卡片已登记 单元格=%@ 内容=%@",
                                  NSStringFromCGRect(cell.frame), NSStringFromCGRect(self.frame)]);
                if (hnpmHidden) {
                    self.hidden = YES;
                    cell.hidden = YES;
                } else if (cell.hidden) {
                    cell.hidden = NO;   // 自愈: 清理上次遗留的隐藏状态
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
        if (self.frame.size.width > 0) {
            HNPMLogThrottled([NSString stringWithFormat:@"[灵动岛] 元素内容登记 frame=%@",
                              NSStringFromCGRect(self.frame)]);
        }
        if (hnpmHidden) self.hidden = YES;
    } @catch (NSException *e) {}
}
%end
%end

// 灵动岛: 门户容器(媒体内容远程渲染)
%group HNPMIslandPortal
%hook _SAUIProvidedViewContainerView
- (void)didMoveToWindow {
    %orig;
    @try {
        if (!self.window) return;
        [hnpmIslandViews addObject:self];
        if (self.frame.size.width > 0) {
            HNPMLogThrottled([NSString stringWithFormat:@"[灵动岛] 门户登记 frame=%@",
                              NSStringFromCGRect(self.frame)]);
        }
        if (hnpmHidden) self.hidden = YES;
    } @catch (NSException *e) {}
}
%end
%end

#pragma mark - 入口

__attribute__((constructor)) static void HNPMRawCtor(void) {
    HNPMAppendLog(@"v0.0.13: dylib 构造函数已执行(dyld 加载成功)");
}

%ctor {
    @autoreleasepool {
        HNPMAppendLog(@"v0.0.13: logos %ctor 进入");

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

        if (objc_getClass("CSActivityItemContentView"))       { %init(HNPMActivityCard); HNPMAppendLog(@"hook 已注册: 媒体卡片(尺寸过滤>=300x140)"); }
        if (objc_getClass("_SAUIElementViewContentView"))     { %init(HNPMIslandElement); }
        if (objc_getClass("_SAUIProvidedViewContainerView"))  { %init(HNPMIslandPortal); }
        HNPMAppendLog(@"v0.0.13: %ctor 正常完成(动画+全量修复+通知保护)");
    }
}
