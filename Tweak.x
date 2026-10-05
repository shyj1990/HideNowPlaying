// HideNowPlaying v0.0.16 — 蒙版收缩灵动岛 + 卡片恢复重试
//
// v0.0.15 用户反馈:
//   ✅ 灵动岛盖板: 无闪烁、恢复瞬间内容完整(方案方向正确)
//   ❌ 盖板比正常岛长(媒体展开宽度) → 改用"蒙版": 只露出容器中间紧凑区域(166pt),
//      岛视觉上收缩为待机短胶囊, 周围是壁纸; 远程内容图层仍活着, 摘蒙版即恢复
//   ❌ 卡片暂停→播放后未滑回 → 日志: 恢复跑了但空壳过滤没找到合格单元格
//      (内容恰在重建/搬家), 且恢复后新登记内容无自动恢复机制
//      → 修复: 恢复多轮重试(0/0.5/1/2/3.5/5s) + 登记时自动恢复(淡入)
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
static NSHashTable *hnpmCardCells = nil;        // 弱引用: 出现过的媒体卡片单元格
static NSHashTable *hnpmIslandContainers = nil; // 弱引用: 灵动岛容器
static void *kHNPMPanKey = &kHNPMPanKey;

#pragma mark - MediaRemote

typedef void (*HNPMGetInfoFunc)(dispatch_queue_t, void (^)(CFDictionaryRef));
static HNPMGetInfoFunc hnpmGetInfo = NULL;

#pragma mark - 媒体卡片判定

// 媒体卡片内容宽度(高度在重建瞬间可能还没布局好, 只按宽度判)
static BOOL HNPMIsMediaSized(CGSize size) {
    return size.width >= 300;
}

// 单元格 subtree 里是否还有媒体内容视图(空壳=内容已迁走 → NO)
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

#pragma mark - 灵动岛蒙版(收缩为紧凑胶囊)

// 只露出容器中间 166pt 的紧凑胶囊区域, 其余(媒体展开部分)被裁掉;
// 纯渲染树操作, 远程内容图层不受影响, 摘掉蒙版即恢复
static void HNPMApplyIslandMask(UIView *container) {
    @try {
        if (!container || !container.window) return;
        CGSize bs = container.bounds.size;
        if (bs.width < 100 || bs.height < 20) return;   // 尺寸未就绪
        CAShapeLayer *mask = (CAShapeLayer *)container.layer.mask;
        if (![mask isKindOfClass:[CAShapeLayer class]]) {
            mask = [[CAShapeLayer alloc] init];
            mask.fillColor = [UIColor whiteColor].CGColor;
            container.layer.mask = mask;
            HNPMLogThrottled(@"[灵动岛] 蒙版已应用(收缩为紧凑胶囊)");
        }
        CGFloat compactW = 166.0;
        CGRect pill = CGRectMake((bs.width - compactW) / 2.0, 0, compactW, bs.height);
        mask.frame = container.bounds;
        mask.path = [UIBezierPath bezierPathWithRoundedRect:pill cornerRadius:bs.height / 2.0].CGPath;
    } @catch (NSException *e) {}
}

static void HNPMRemoveIslandMasks(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            for (UIView *container in hnpmIslandContainers) {
                if (container.layer.mask) {
                    container.layer.mask = nil;
                    HNPMLogThrottled(@"[灵动岛] 蒙版已摘除");
                }
            }
        } @catch (NSException *e) {}
    });
}

#pragma mark - 卡片隐藏 / 恢复

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

// 恢复: 只恢复"仍挂着媒体内容"的单元格(空壳不碰); 幂等, 供多轮重试调用
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

// 恢复多轮重试: 内容重建/搬家发生在恢复瞬间, 首轮可能找不到, 反复尝试兜底
static void HNPMRestoreWithRetries(void) {
    NSArray *delays = @[@0.0, @0.5, @1.0, @2.0, @3.5, @5.0];
    for (NSNumber *d in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)([d doubleValue] * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try {
                if (!hnpmHidden) HNPMShowCards();
            } @catch (NSException *e) {}
        });
    }
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
                for (UIView *c in hnpmIslandContainers) HNPMApplyIslandMask(c);
            } @catch (NSException *e) {}
        });
    } else {
        HNPMRestoreWithRetries();
        HNPMRemoveIslandMasks();
    }
    HNPMAppendLog([NSString stringWithFormat:@"%@ → 状态=%@",
                   reason, hide ? @"已隐藏(音乐继续)" : @"已恢复显示"]);
}

// 0.5 秒轮询: ① 隐藏期间同步蒙版(容器尺寸变化) ② 检测"暂停→继续播放"
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
                    dispatch_async(dispatch_get_main_queue(), ^{
                        @try {
                            for (UIView *c in hnpmIslandContainers) HNPMApplyIslandMask(c);
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
                } else if (cell.hidden || self.hidden) {
                    // 恢复期(或历史遗留)登记 → 自动恢复显示(淡入)
                    self.hidden = NO;
                    cell.transform = CGAffineTransformIdentity;
                    cell.alpha = 0.0;
                    cell.hidden = NO;
                    [UIView animateWithDuration:0.35 animations:^{ cell.alpha = 1.0; }];
                    HNPMAppendLog(@"[卡片] 恢复期登记 → 自动恢复显示");
                }
            } @catch (NSException *e) {}
        });
    } @catch (NSException *e) {}
}
%end
%end

// 灵动岛容器: 只登记(蒙版方案, 不碰系统视图属性)
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
                @try { HNPMApplyIslandMask(self); } @catch (NSException *e) {}
            });
        }
    } @catch (NSException *e) {}
}
%end
%end

#pragma mark - 入口

__attribute__((constructor)) static void HNPMRawCtor(void) {
    HNPMAppendLog(@"v0.0.16: dylib 构造函数已执行(dyld 加载成功)");
}

%ctor {
    @autoreleasepool {
        HNPMAppendLog(@"v0.0.16: logos %ctor 进入");

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

        if (objc_getClass("CSActivityItemContentView"))      { %init(HNPMActivityCard); HNPMAppendLog(@"hook 已注册: 媒体卡片(宽度过滤>=300)"); }
        if (objc_getClass("SBSystemApertureContainerView"))  { %init(HNPMIslandContainer); HNPMAppendLog(@"hook 已注册: 灵动岛容器(蒙版方案)"); }
        HNPMAppendLog(@"v0.0.16: %ctor 正常完成(蒙版+恢复重试)");
    }
}
