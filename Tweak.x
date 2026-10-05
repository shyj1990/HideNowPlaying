// HideNowPlaying v0.0.38 — 岛内容隐藏(塌缩) + 播放信息重推送唤活
//
// v0.0.17 实测结论: 窗口级蒙版应用成功但仍裁不住媒体内容 → 蒙版路线放弃
//   (容器级蒙版 v0.0.16 失败, 窗口级蒙版 v0.0.17 也失败)
//
// v0.0.38 方案(回到实测有效路径 + 修黑壳):
//   隐藏: 藏岛的内容视图(_SAUIElementViewContentView + 宽>=30 的门户)
//         → 岛塌缩为待机短胶囊(v0.0.12/13 用户满意的效果)
//   恢复: ① 取消隐藏(登记表 + 全窗口类扫描兜底)
//         ② "唤活": 通过 MRMediaRemoteSetNowPlayingInfo 把当前播放信息重新推送一次,
//            逼远程进程重新渲染内容 —— 推送时视图已可见, 黑壳应被真实内容替换
//            (0.5s/1.5s/3s 推送三次, 每次都先取最新播放信息)
//   卡片: 维持 v0.0.16 逻辑(实测可靠: 滑出动画 + 恢复重试 + 登记自愈)
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
static NSHashTable *hnpmCardCells = nil;     // 弱引用: 媒体卡片单元格
static NSHashTable *hnpmCardContents = nil;  // 弱引用: 卡片内容视图(恢复时需一并显示)
static __weak UIView *hnpmHiddenCard = nil;  // 被左滑隐藏的那张"正在播放"卡片

static void HNPMHideCard(UIView *cell);

// 媒体(正在播放)卡片永远位于通知列表最底部 —— 只认最底下那张, 其他 App 的实时活动不碰
static BOOL HNPMIsBottomMostMediaCell(UIView *cell) {
    if (!cell || !cell.window) return NO;
    CGRect r = [cell convertRect:cell.bounds toView:nil];
    CGFloat myY = r.origin.y + r.size.height;
    CGFloat bestY = -CGFLOAT_MAX;
    for (UIView *c in hnpmCardCells) {
        if (!c.window || c == cell) continue;
        CGRect cr = [c convertRect:c.bounds toView:nil];
        CGFloat cy = cr.origin.y + cr.size.height;
        if (cy > bestY) bestY = cy;
    }
    // 有其他登记卡片明显更低(>24pt) → 我不是正在播放卡片
    return (bestY > 0 && bestY - myY > 24.0) ? NO : YES;
}
static NSHashTable *hnpmIslandViews = nil;   // 弱引用: 灵动岛内容视图
static void *kHNPMPanKey = &kHNPMPanKey;

#pragma mark - MediaRemote

typedef void (*HNPMGetInfoFunc)(dispatch_queue_t, void (^)(CFDictionaryRef));
static HNPMGetInfoFunc hnpmGetInfo = NULL;
#pragma mark - 媒体卡片判定

static BOOL HNPMIsMediaSized(CGSize size) {
    // 正在播放卡片高约 167; 其他实时活动约 ≤143(侦察实测) → 高度 150 为分界
    return size.width >= 300 && size.height >= 150;
}

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

// 灵动岛窗口整体隐藏(基线方案: 实验证明按内容筛选无效——媒体与活动同住一个窗口)
static void HNPMSetApertureWindowsHidden(BOOL hide, NSString *tag) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            int n = 0;
            for (UIWindow *w in [UIApplication sharedApplication].windows) {
                if (![NSStringFromClass([w class]) containsString:@"Aperture"]) continue;
                if (w.isHidden != hide) { w.hidden = hide; n++; }
            }
            if (n > 0) HNPMAppendLog([NSString stringWithFormat:@"[岛窗] %@ %d 个灵动岛窗口→%@",
                                      tag, n, hide ? @"隐藏" : @"显示"]);
        } @catch (NSException *e) {}
    });
}

#pragma mark - 卡片隐藏 / 恢复

// 只隐藏被左滑的那张"正在播放"卡片(不动其他实时活动)
static void HNPMHideCard(UIView *cell) {
    if (!cell || !cell.window) return;
    hnpmHiddenCard = cell;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
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
        } @catch (NSException *e) {}
    });
}

static void HNPMShowCards(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            // 内容视图放回来(隐藏期新建的卡片, 内容视图被单独藏过; 不放回来就是白片)
            for (UIView *content in hnpmCardContents) {
                if (content.window && content.isHidden) content.hidden = NO;
            }
            // 找要恢复的卡片: 优先被左滑那张; 系统重建过就找最底部的隐藏媒体卡片
            UIView *cell = hnpmHiddenCard;
            if (!cell || !cell.window) {
                CGFloat bestY = -CGFLOAT_MAX;
                for (UIView *c in hnpmCardCells) {
                    if (!c.window || !c.hidden || !HNPMCellHasLiveMedia(c)) continue;
                    CGRect cr = [c convertRect:c.bounds toView:nil];
                    CGFloat cy = cr.origin.y + cr.size.height;
                    if (cy > bestY) { bestY = cy; cell = c; }
                }
            }
            if (!cell || !cell.window || !HNPMCellHasLiveMedia(cell)) return;
            // 已在显示中 → 不再重复动画(防恢复重试导致的闪烁)
            if (!cell.hidden) return;
            cell.hidden = NO;
            cell.transform = CGAffineTransformTranslate(CGAffineTransformIdentity, -440, 0);
            cell.alpha = 0.0;
            [UIView animateWithDuration:0.35
                                      delay:0.0
                                    options:UIViewAnimationOptionCurveEaseOut
                                 animations:^{
                cell.transform = CGAffineTransformIdentity;
                cell.alpha = 1.0;
            }
                                 completion:nil];
            HNPMAppendLog(@"[卡片] 恢复显示(带媒体内容的单元格)");
        } @catch (NSException *e) {}
    });
}

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
        // 卡片已由 handlePan 单独隐藏(只动"正在播放"那张)
        HNPMSetApertureWindowsHidden(YES, @"隐藏");
    } else {
        HNPMRestoreWithRetries();
        HNPMSetApertureWindowsHidden(NO, @"恢复");
    }
    HNPMAppendLog([NSString stringWithFormat:@"%@ → 状态=%@",
                   reason, hide ? @"已隐藏(音乐继续)" : @"已恢复显示"]);
}

// 0.5 秒轮询: 隐藏期间检测"暂停→继续播放"; 维持灵动岛窗口隐藏(系统重开就再藏)
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
                            HNPMSetApertureWindowsHidden(YES, @"轮询");
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
        // 只认"正在播放"卡片; 侦察模式下记录判定细节
        Class cellClass = NSClassFromString(@"NCNotificationListCell");
        UIView *p = gr.view;
        while (p && ![p isKindOfClass:cellClass]) p = p.superview;
        if (!p) return;
        BOOL accept = HNPMIsBottomMostMediaCell(p);
        @try {
            CGRect wr = [p convertRect:p.bounds toView:nil];
            CGFloat myY = wr.origin.y + wr.size.height;
            CGFloat bestY = -CGFLOAT_MAX;
            for (UIView *c in hnpmCardCells) {
                if (!c.window || c == p) continue;
                CGRect cr = [c convertRect:c.bounds toView:nil];
                CGFloat cy = cr.origin.y + cr.size.height;
                if (cy > bestY) bestY = cy;
            }
            HNPMAppendLog([NSString stringWithFormat:@"[判定] 触摸单元格 win=%@ myY=%.0f bestY=%.0f cells=%lu → %@",
                           NSStringFromCGRect(wr), myY, bestY, (unsigned long)hnpmCardCells.count,
                           accept ? @"接受(当作正在播放卡)" : @"拒绝(当作其他实时活动)"]);
        } @catch (NSException *e) {}
        if (!accept) return;
        CGPoint t = [gr translationInView:gr.view];
        CGPoint v = [gr velocityInView:gr.view];
        if (gr.state == UIGestureRecognizerStateChanged) {
            if (t.x < -60 && fabs(t.x) > fabs(t.y) * 1.5) {
                HNPMHideCard(p);
                HNPMSetHidden(YES, @"锁屏播放卡片左滑");
                HNPMStartRestorePolling();
            }
        } else if (gr.state == UIGestureRecognizerStateEnded) {
            if (t.x < -55 && fabs(t.x) > fabs(t.y) * 1.2 && v.x < -300) {
                HNPMHideCard(p);
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
                if (!HNPMIsMediaSized(self.frame.size)) return;
                Class cellClass = NSClassFromString(@"NCNotificationListCell");
                UIView *p = self;
                while (p && ![p isKindOfClass:cellClass]) p = p.superview;
                if (!p) return;
                UIView *cell = p;
                [hnpmCardCells addObject:cell];
                [hnpmCardContents addObject:self];
                HNPMAttachPanIfNeeded(cell);
                // 侦察: 单元格/内容的 frame + 窗口坐标 + 上两级容器类名(判定依据)
                CGRect winR = [cell convertRect:cell.bounds toView:nil];
                CGRect winC = [self convertRect:self.bounds toView:nil];
                NSString *p1 = [[cell superview] class] ? NSStringFromClass([[cell superview] class]) : @"无";
                NSString *p2 = [[cell superview] superview] ? NSStringFromClass([[cell superview] superview].class) : @"无";
                HNPMAppendLog([NSString stringWithFormat:@"[卡片] 登记 单元格 frame=%@ win=%@ 内容 frame=%@ win=%@ 容器=%@/%@",
                               NSStringFromCGRect(cell.frame), NSStringFromCGRect(winR),
                               NSStringFromCGRect(self.frame), NSStringFromCGRect(winC), p1, p2]);
                if (hnpmHidden && HNPMIsBottomMostMediaCell(cell)) {
                    // 隐藏期"正在播放"卡片被系统重建 → 保持隐藏; 其他实时活动不受影响
                    self.hidden = YES;
                    cell.hidden = YES;
                } else if (HNPMIsBottomMostMediaCell(cell) && (cell.hidden || self.hidden)) {
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

// 灵动岛: 元素内容视图(锁图标+媒体图标)
%group HNPMIslandElement
%hook _SAUIElementViewContentView
- (void)didMoveToWindow {
    %orig;
    @try {
        if (!self.window) return;
        [hnpmIslandViews addObject:self];
        HNPMLogThrottled([NSString stringWithFormat:@"[灵动岛] 元素内容登记 frame=%@",
                          NSStringFromCGRect(self.frame)]);
        // v0.0.38: 不再隐藏内容(藏窗口方案, 内容保持存活)
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
        HNPMLogThrottled([NSString stringWithFormat:@"[灵动岛] 门户登记 frame=%@",
                          NSStringFromCGRect(self.frame)]);
        // v0.0.38: 不再隐藏内容(藏窗口方案, 内容保持存活)
    } @catch (NSException *e) {}
}
%end
%end

#pragma mark - 入口

__attribute__((constructor)) static void HNPMRawCtor(void) {
    HNPMAppendLog(@"v0.0.38: dylib 构造函数已执行(dyld 加载成功)");
}

// 侦察: 灵动岛"元素管理器"是否存在及其方法签名(模型级方案的前提)
static void HNPMReconApertureManager(void) {
    @try {
        NSArray *names = @[@"SBSystemApertureElementManager", @"SBApertureElementManager",
                           @"SBSystemApertureModel", @"SBSystemApertureClient",
                           @"SBSystemApertureStateManager", @"SBFApertureManager"];
        for (NSString *nm in names) {
            Class c = NSClassFromString(nm);
            if (!c) { HNPMAppendLog([NSString stringWithFormat:@"[岛管理] %@ 不存在", nm]); continue; }
            HNPMAppendLog([NSString stringWithFormat:@"[岛管理] %@ 存在", nm]);
            unsigned int pc = 0;
            objc_property_t *props = class_copyPropertyList(c, &pc);
            for (unsigned int i = 0; i < pc; i++) {
                NSString *p = [NSString stringWithCString:property_getName(props[i]) encoding:NSUTF8StringEncoding];
                HNPMAppendLog([NSString stringWithFormat:@"[岛管理] %@ 属性 %@", nm, p]);
            }
            free(props);
            unsigned int mc = 0;
            Method *ms = class_copyMethodList(object_getClass(c), &mc);
            for (unsigned int i = 0; i < mc; i++) {
                NSString *s = NSStringFromSelector(method_getName(ms[i]));
                if ([s containsString:@"shared"] || [s containsString:@"instance"] || [s containsString:@"anager"])
                    HNPMAppendLog([NSString stringWithFormat:@"[岛管理] %@ 类方法 %@", nm, s]);
            }
            free(ms);
            mc = 0;
            ms = class_copyMethodList(c, &mc);
            for (unsigned int i = 0; i < mc; i++) {
                NSString *s = NSStringFromSelector(method_getName(ms[i]));
                if ([s containsString:@"lement"] || [s containsString:@"ctivity"] || [s containsString:@"edia"]
                    || [s containsString:@"playing"] || [s containsString:@"isplay"] || [s containsString:@"resent"])
                    HNPMAppendLog([NSString stringWithFormat:@"[岛管理] %@ 实例方法 %@", nm, s]);
            }
            free(ms);
        }
    } @catch (NSException *e) {
        HNPMAppendLog(@"[岛管理] 侦察异常");
    }
}

static id gHNPMIslandController = nil;
static int gHNPMElementDumped = 0;

%group(HNPMIslandController)
%hook(SBSystemApertureController)
- (void)registerElement:(id)el {
    %orig;
    @try {
        gHNPMIslandController = self;
        if (!gHNPMElementDumped) {
            gHNPMElementDumped = 1;
            NSString *desc = [el description];
            if ([desc length] > 300) desc = [desc substringToIndex:300];
            HNPMAppendLog([NSString stringWithFormat:@"[元素] 注册(%@): %@", NSStringFromClass([el class]), desc]);
            unsigned int mc = 0;
            Method *ms = class_copyMethodList([el class], &mc);
            for (unsigned int i = 0; i < mc; i++) {
                NSString *s = NSStringFromSelector(method_getName(ms[i]));
                if ([s containsString:@"dentif"] || [s containsString:@"isib"] || [s containsString:@"uppress"]
                    || [s containsString:@"Hide"] || [s containsString:@"emov"] || [s containsString:@"ctivat"]
                    || [s containsString:@"riorit"] || [s containsString:@"nabl"] || [s containsString:@"ontent"])
                    HNPMAppendLog([NSString stringWithFormat:@"[元素]   方法 %@", s]);
            }
            free(ms);
        } else {
            HNPMAppendLog([NSString stringWithFormat:@"[元素] 注册 %@", NSStringFromClass([el class])]);
        }
    } @catch (NSException *e) {}
}
- (id)_currentFirstElement {
    @try {
        if (!gHNPMIslandController) {
            gHNPMIslandController = self;
            HNPMAppendLog(@"[岛控] 控制器已捕获(经 _currentFirstElement)");
        }
    } @catch (NSException *e) {}
    return %orig;
}
- (id)acquireSuppressionAssertionForBackgroundActivities:(id)a reason:(id)r {
    @try {
        HNPMAppendLog([NSString stringWithFormat:@"[岛控] 系统取后台活动抑制断言: arg=%@ reason=%@",
                       NSStringFromClass([a class]), r]);
    } @catch (NSException *e) {}
    return %orig;
}
- (void)suppressSystemApertureCompletelyWithReason:(id)r {
    @try { HNPMAppendLog([NSString stringWithFormat:@"[岛控] 系统整岛抑制: %@", r]); } @catch (NSException *e) {}
    %orig;
}
%end
%end

// 侦察: 枚举运行时所有含 Aperture 的类及其方法(找出真正的元素管理器)
static void HNPMReconApertureClasses(void) {
    @try {
        unsigned int count = 0;
        Class *classes = objc_copyClassList(&count);
        if (!classes) return;
        int hits = 0;
        for (unsigned int i = 0; i < count && hits < 40; i++) {
            NSString *nm = NSStringFromClass(classes[i]);
            if (![nm containsString:@"Aperture"]) continue;
            hits++;
            HNPMAppendLog([NSString stringWithFormat:@"[岛类] %@", nm]);
            // 只对 Manager/Model/Controller/State 类深挖方法
            if (![nm containsString:@"Manager"] && ![nm containsString:@"Model"]
                && ![nm containsString:@"Controller"] && ![nm containsString:@"State"]
                && ![nm containsString:@"Coordinator"]) continue;
            unsigned int mc = 0;
            Method *ms = class_copyMethodList(classes[i], &mc);
            for (unsigned int j = 0; j < mc; j++) {
                NSString *s = NSStringFromSelector(method_getName(ms[j]));
                if ([s containsString:@"lement"] || [s containsString:@"ctivity"] || [s containsString:@"edia"]
                    || [s containsString:@"playing"] || [s containsString:@"resent"] || [s containsString:@"isplay"])
                    HNPMAppendLog([NSString stringWithFormat:@"[岛类]   方法 %@", s]);
            }
            free(ms);
        }
        free(classes);
        HNPMAppendLog([NSString stringWithFormat:@"[岛类] 枚举完成, 命中 %d 个", hits]);
    } @catch (NSException *e) {
        HNPMAppendLog(@"[岛类] 枚举异常");
    }
}

// 侦察: SBSystemApertureController 完整方法表 + 单例 + 当前元素 + 抑制断言类
static void HNPMReconApertureController(void) {
    @try {
        Class c = NSClassFromString(@"SBSystemApertureController");
        if (!c) { HNPMAppendLog(@"[岛控] SBSystemApertureController 不存在"); return; }
        unsigned int mc = 0;
        Method *ms = class_copyMethodList(object_getClass(c), &mc);
        for (unsigned int i = 0; i < mc; i++) {
            NSString *s = NSStringFromSelector(method_getName(ms[i]));
            if ([s containsString:@"shared"] || [s containsString:@"Instance"])
                HNPMAppendLog([NSString stringWithFormat:@"[岛控] 类方法 %@", s]);
        }
        free(ms);
        ms = class_copyMethodList(c, &mc);
        for (unsigned int i = 0; i < mc; i++)
            HNPMAppendLog([NSString stringWithFormat:@"[岛控] 方法 %@",
                           NSStringFromSelector(method_getName(ms[i]))]);
        free(ms);
        id inst = nil;
        SEL sh = NSSelectorFromString(@"sharedInstance");
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        if ([c respondsToSelector:sh]) inst = [(id)c performSelector:sh];
        HNPMAppendLog([NSString stringWithFormat:@"[岛控] 单例=%@", inst]);
        if ([inst respondsToSelector:NSSelectorFromString(@"_currentFirstElement")]) {
            id el = [inst performSelector:NSSelectorFromString(@"_currentFirstElement")];
#pragma clang diagnostic pop
            NSString *desc = [el description];
            if (desc.length > 400) desc = [desc substringToIndex:400];
            HNPMAppendLog([NSString stringWithFormat:@"[岛控] 当前元素(%@)=%@",
                           NSStringFromClass([el class]), desc]);
        }
        for (NSString *nm in @[@"_SBSystemApertureRepresentationSuppressionAssertion",
                               @"SBRequestSystemApertureElementSuppressionEventResponse"]) {
            Class sc = NSClassFromString(nm);
            if (!sc) { HNPMAppendLog([NSString stringWithFormat:@"[岛控] %@ 不存在", nm]); continue; }
            unsigned int sc2 = 0;
            Method *sm = class_copyMethodList(sc, &sc2);
            for (unsigned int i = 0; i < sc2; i++)
                HNPMAppendLog([NSString stringWithFormat:@"[岛控] %@ 方法 %@", nm,
                               NSStringFromSelector(method_getName(sm[i]))]);
            free(sm);
        }
    } @catch (NSException *e) {
        HNPMAppendLog([NSString stringWithFormat:@"[岛控] 侦察异常: %@", e.reason]);
    }
}

%ctor {
    @autoreleasepool {
        HNPMAppendLog(@"v0.0.38: logos %ctor 进入");

        if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/Documents/HideNowPlaying.off"]) {
            HNPMAppendLog(@"检测到开关文件 HideNowPlaying.off, 不注册任何 hook");
            return;
        }

        hnpmCardCells = [NSHashTable weakObjectsHashTable];
        hnpmCardContents = [NSHashTable weakObjectsHashTable];
        hnpmIslandViews = [NSHashTable weakObjectsHashTable];
        hnpmPanTarget = [[HNPMPanTarget alloc] init];

        void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
        if (mr) {
            hnpmGetInfo = (HNPMGetInfoFunc)dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
            HNPMAppendLog([NSString stringWithFormat:@"MediaRemote 已加载, 播放检测%@",
                           hnpmGetInfo ? @"可用" : @"不可用"]);
        } else {
            HNPMAppendLog(@"MediaRemote 加载失败");
        }

        if (objc_getClass("CSActivityItemContentView"))      { %init(HNPMActivityCard); HNPMAppendLog(@"hook 已注册: 媒体卡片(高度>=150 过滤)"); }
        if (objc_getClass("_SAUIElementViewContentView"))    { %init(HNPMIslandElement); }
        if (objc_getClass("_SAUIProvidedViewContainerView")) { %init(HNPMIslandPortal); }
        if (objc_getClass("SBSystemApertureController"))     { %init(HNPMIslandController); HNPMAppendLog(@"hook 已注册: 岛控制器捕获"); }
        HNPMReconApertureManager();
        HNPMReconApertureClasses();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            HNPMReconApertureController();
        });
        HNPMAppendLog(@"v0.0.38: %ctor 正常完成");
    }
}
