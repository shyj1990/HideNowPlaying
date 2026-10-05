// HideNowPlaying v0.0.15 — 灵动岛盖板方案 + 空壳单元格根治
//
// v0.0.14 用户反馈:
//   ❌ 左滑后灵动岛封面/波纹一闪一闪 → 根因: 系统对灵动岛容器持续做 alpha 动画(媒体脉冲),
//      我们每 0.5s 压回 0, 双方打架 = 闪烁
//   ❌ 暂停→播放后卡片变白色一片 → 根因: 日志证实媒体卡片内容每 5~12 秒重建一次,
//      恢复时把所有登记过的单元格都恢复, 旧的空壳单元格(内容已迁走)也显示 = 白板
//
// v0.0.15 方案:
//   灵动岛: 完全不碰系统视图属性! 用自己的黑色胶囊"盖板"视图盖在岛上方:
//     - 远程内容图层继续在渲染树里活着渲染(恢复零黑壳)
//     - 盖板是我们自己的视图, 系统动画碰不到它(零闪烁)
//     - 恢复时淡出移除盖板, 内容瞬间可见
//     - 隐藏期间每 0.5s 同步盖板位置(岛尺寸变化时跟随)
//   卡片: 恢复时只恢复"仍挂着媒体内容(>=300x140 的 CSActivityItemContentView)"的单元格;
//     空壳单元格永远不碰 → 白板根治
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
static NSHashTable *hnpmCardCells = nil;      // 弱引用: 出现过的媒体卡片单元格
static NSHashTable *hnpmIslandContainers = nil; // 弱引用: 灵动岛容器
static void *kHNPMPanKey = &kHNPMPanKey;
static void *kHnpmCoverKey = &kHnpmCoverKey;  // 关联对象: 容器 → 盖板

#pragma mark - MediaRemote

typedef void (*HNPMGetInfoFunc)(dispatch_queue_t, void (^)(CFDictionaryRef));
static HNPMGetInfoFunc hnpmGetInfo = NULL;

#pragma mark - 媒体卡片判定

static BOOL HNPMIsMediaSized(CGSize size) {
    return size.width >= 300 && size.height >= 140;
}

// 单元格 subtree 里是否还有"活的"媒体内容(尺寸过滤, 空壳=内容已迁走 → NO)
static BOOL HNPMCellHasLiveMedia(UIView *cell) {
    @try {
        if (!cell) return NO;
        Class contentClass = objc_getClass("CSActivityItemContentView");
        if (!contentClass) return NO;
        NSMutableArray *stack = [NSMutableArray arrayWithObject:cell];
        int guard = 0;
        while (stack.count > 0 && guard++ < 200) {
            UIView *v = stack.firstObject;
            [stack removeObjectAtIndex:0];
            if (!v) continue;
            if ([v isKindOfClass:contentClass] && HNPMIsMediaSized(v.frame.size)) return YES;
            [stack addObjectsFromArray:[v subviews]];
        }
    } @catch (NSException *e) {}
    return NO;
}

#pragma mark - 灵动岛盖板

static void HNPMSyncCover(UIView *container, BOOL create) {
    @try {
        if (!container || !container.window) return;
        UIView *cover = objc_getAssociatedObject(container, kHnpmCoverKey);
        CGRect frame = [container convertRect:container.bounds toView:nil];
        if (!cover && create) {
            cover = [[UIView alloc] initWithFrame:frame];
            cover.backgroundColor = [UIColor blackColor];
            cover.layer.cornerRadius = 19.0;
            cover.userInteractionEnabled = NO;
            objc_setAssociatedObject(container, kHnpmCoverKey, cover, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [container.window addSubview:cover];
            HNPMLogThrottled([NSString stringWithFormat:@"[灵动岛] 盖板已放置 frame=%@", NSStringFromCGRect(frame)]);
        }
        if (cover) {
            if (!CGRectEqualToRect(cover.frame, frame)) {
                [UIView performWithoutAnimation:^{
                    cover.frame = frame;
                    cover.layer.cornerRadius = fmin(24.0, fmax(10.0, frame.size.height / 2.0));
                }];
            }
        }
    } @catch (NSException *e) {}
}

static void HNPMRemoveCovers(BOOL animated) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            for (UIView *container in hnpmIslandContainers) {
                UIView *cover = objc_getAssociatedObject(container, kHnpmCoverKey);
                if (!cover) continue;
                objc_setAssociatedObject(container, kHnpmCoverKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                if (animated && cover.superview) {
                    [UIView animateWithDuration:0.25 animations:^{ cover.alpha = 0.0; }
                                     completion:^(BOOL finished) {
                        [cover removeFromSuperview];
                    }];
                } else {
                    [cover removeFromSuperview];
                }
            }
        } @catch (NSException *e) {}
    });
}

#pragma mark - 隐藏 / 恢复

// 隐藏: 当前活的媒体卡片全部滑出
static void HNPMHideCards(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            for (UIView *cell in hnpmCardCells) {
                if (!cell.window) continue;
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
            }
        } @catch (NSException *e) {}
    });
}

// 恢复: 只恢复"仍挂着媒体内容"的单元格(空壳不碰 → 白板根治)
static void HNPMShowCards(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            for (UIView *cell in hnpmCardCells) {
                if (!cell.window) continue;
                if (!HNPMCellHasLiveMedia(cell)) continue;   // 空壳: 保持隐藏
                if (!cell.hidden && CGAffineTransformIsIdentity(cell.transform) && cell.alpha >= 1.0) continue;
                Class contentClass = objc_getClass("CSActivityItemContentView");
                if (contentClass) {
                    NSMutableArray *stack = [NSMutableArray arrayWithObject:cell];
                    int guard = 0;
                    while (stack.count > 0 && guard++ < 200) {
                        UIView *v = stack.firstObject;
                        [stack removeObjectAtIndex:0];
                        if (!v) continue;
                        if ([v isKindOfClass:contentClass]) v.hidden = NO;
                        [stack addObjectsFromArray:[v subviews]];
                    }
                }
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
                HNPMAppendLog(@"[卡片] 恢复显示(带媒体内容的单元格)");
            }
        } @catch (NSException *e) {}
    });
}

static void HNPMSetHidden(BOOL hide, NSString *reason) {
    if (hide == hnpmHidden) return;
    hnpmHidden = hide;
    hnpmBaseline = NO;
    hnpmPauseStreak = 0;
    if (hide) {
        HNPMHideCards();
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                for (UIView *c in hnpmIslandContainers) HNPMSyncCover(c, YES);
            } @catch (NSException *e) {}
        });
    } else {
        HNPMShowCards();
        HNPMRemoveCovers(YES);
    }
    HNPMAppendLog([NSString stringWithFormat:@"%@ → 状态=%@",
                   reason, hide ? @"已隐藏(音乐继续)" : @"已恢复显示"]);
}

// 0.5 秒轮询: ① 隐藏期间同步盖板位置 ② 检测"暂停→继续播放"
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
                    // 盖板跟随岛的位置/尺寸
                    dispatch_async(dispatch_get_main_queue(), ^{
                        @try {
                            for (UIView *c in hnpmIslandContainers) HNPMSyncCover(c, YES);
                        } @catch (NSException *e) {}
                    });
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
    } @catch (NSException *e) {}
}

#pragma mark - 类声明

@interface CSActivityItemContentView : UIView @end
@interface SBSystemApertureContainerView : UIView @end
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
                [hnpmCardCells addObject:cell];
                HNPMAttachPanIfNeeded(cell);
                HNPMLogThrottled([NSString stringWithFormat:@"[卡片] 媒体卡片登记 单元格=%@ 内容=%@",
                                  NSStringFromCGRect(cell.frame), NSStringFromCGRect(self.frame)]);
                if (hnpmHidden) {
                    // 隐藏期间新出现的卡片: 直接隐藏(无动画)
                    self.hidden = YES;
                    cell.hidden = YES;
                }
                // 注意: 不在此处恢复显示(恢复统一走 HNPMShowCards 的空壳过滤)
            } @catch (NSException *e) {}
        });
    } @catch (NSException *e) {}
}
%end
%end

// 灵动岛容器: 只登记位置(盖板方案, 不碰任何系统属性)
%group HNPMIslandContainer
%hook SBSystemApertureContainerView
- (void)didMoveToWindow {
    %orig;
    @try {
        if (!self.window) return;
        [hnpmIslandContainers addObject:self];
        HNPMLogThrottled([NSString stringWithFormat:@"[灵动岛] 容器登记 frame=%@", NSStringFromCGRect(self.frame)]);
        if (hnpmHidden) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                @try { HNPMSyncCover(self, YES); } @catch (NSException *e) {}
            });
        }
    } @catch (NSException *e) {}
}
%end
%end

#pragma mark - 入口

__attribute__((constructor)) static void HNPMRawCtor(void) {
    HNPMAppendLog(@"v0.0.15: dylib 构造函数已执行(dyld 加载成功)");
}

%ctor {
    @autoreleasepool {
        HNPMAppendLog(@"v0.0.15: logos %ctor 进入");

        if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/Documents/HideNowPlaying.off"]) {
            HNPMAppendLog(@"检测到开关文件 HideNowPlaying.off, 不注册任何 hook");
            return;
        }

        hnpmCardCells = [NSHashTable weakObjectsHashTable];
        hnpmIslandContainers = [NSHashTable weakObjectsHashTable];
        hnpmPanTarget = [[HNPMPanTarget alloc] init];

        void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
        if (mr) {
            hnpmGetInfo = (HNPMGetInfoFunc)dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
            HNPMAppendLog([NSString stringWithFormat:@"MediaRemote 已加载, 播放检测%@", hnpmGetInfo ? @"可用" : @"不可用"]);
        } else {
            HNPMAppendLog(@"MediaRemote 加载失败");
        }

        if (objc_getClass("CSActivityItemContentView"))      { %init(HNPMActivityCard); HNPMAppendLog(@"hook 已注册: 媒体卡片(尺寸过滤>=300x140)"); }
        if (objc_getClass("SBSystemApertureContainerView"))  { %init(HNPMIslandContainer); HNPMAppendLog(@"hook 已注册: 灵动岛容器(盖板方案)"); }
        HNPMAppendLog(@"v0.0.15: %ctor 正常完成(盖板+空壳过滤)");
    }
}
