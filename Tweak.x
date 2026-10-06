// HideNowPlaying v0.0.45 — 岛内媒体内容级隐藏(窗口保持存活, 原生待机观感)
//
// v0.0.44 实测: 整窗隐藏/恢复后媒体正常, 但信号/WiFi/电池与媒体同窗被"陪葬",
//   隐藏期间状态栏不完整。用户要求与原生一致:
//   隐藏期 = 待机观感(信号图标可见) / 恢复后 = 播放观感(媒体展开, 信号让位)。
//
// v0.0.45 方案(内容级隐藏, 回归 v0.0.12/13 路线 + 新抗黑壳手段):
//   隐藏: 只藏岛内媒体内容视图(_SAUIElementViewContentView / _SAUIProvidedViewContainerView
//         且宽>=80 —— 紧凑胶囊约126宽, 展开态160~390, 活动图标一般<50), 窗口不藏
//         → 系统自动回到待机布局: 短胶囊 + 信号图标 + 其他活动图标保留
//   维持: 0.5s 轮询重申隐藏(对抗系统动画), 隐藏期新建的媒体内容由钩子延迟判定拦截
//   恢复: 点亮内容视图 + "原位重新挂载"(摘下再装回, 逼远程渲染重新 attach, 抗黑壳)
//         + 多次重试兜底
//   卡片: 维持原逻辑(实测可靠: 滑出动画 + 恢复重试 + 登记自愈)
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

// v0.0.45: 内容级隐藏 —— 只藏岛内的"媒体内容视图", 窗口保持存活
// 信号/WiFi/电池(尾部元素)与媒体同窗, 整窗隐藏会陪葬 → 内容级隐藏让系统自动回到待机布局
// (隐藏期 = 原生待机观感: 短胶囊 + 信号图标 + 其他活动图标; 恢复后 = 原生播放观感)
static BOOL HNPMIsIslandMediaView(UIView *v) {
    if (!v) return NO;
    NSString *cls = NSStringFromClass([v class]);
    if (![cls isEqualToString:@"_SAUIElementViewContentView"]
        && ![cls isEqualToString:@"_SAUIProvidedViewContainerView"]) return NO;
    return v.bounds.size.width >= 80.0;
}

static void HNPMSetIslandContentHidden(BOOL hide, NSString *tag) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            int n = 0, kicked = 0;
            NSMutableArray *descs = [NSMutableArray array];
            for (UIWindow *w in [UIApplication sharedApplication].windows) {
                if (![NSStringFromClass([w class]) containsString:@"Aperture"]) continue;
                NSMutableArray *stack = [NSMutableArray arrayWithObject:w];
                int guard = 0;
                while (stack.count > 0 && guard++ < 600) {
                    UIView *v = stack.firstObject;
                    [stack removeObjectAtIndex:0];
                    if (!v) continue;
                    [stack addObjectsFromArray:v.subviews];
                    if (!HNPMIsIslandMediaView(v)) continue;
                    if (hide) {
                        if (!v.isHidden) {
                            v.hidden = YES;
                            n++;
                            if (descs.count < 8)
                                [descs addObject:[NSString stringWithFormat:@"%@ %@",
                                                  NSStringFromClass([v class]), NSStringFromCGRect(v.frame)]];
                        }
                    } else if (v.isHidden || v.alpha < 0.05) {
                        v.hidden = NO;
                        v.alpha = 1.0;
                        n++;
                        // 原位重新挂载(摘下再装回) → 逼远程渲染管线重新 attach, 抗黑壳
                        UIView *sp = v.superview;
                        if (sp) {
                            NSUInteger idx = [sp.subviews indexOfObject:v];
                            [v removeFromSuperview];
                            [sp insertSubview:v atIndex:idx];
                            kicked++;
                        }
                    }
                }
            }
            if (n > 0 || [tag isEqualToString:@"隐藏"] || [tag isEqualToString:@"恢复"]) {
                NSString *kick = kicked > 0 ? [NSString stringWithFormat:@"(重新挂载 %d)", kicked] : @"";
                HNPMAppendLog([NSString stringWithFormat:@"[岛内] %@ 媒体内容 %d 个→%@%@ %@",
                               tag, n, hide ? @"隐藏" : @"显示", kick,
                               [descs componentsJoinedByString:@" | "]]);
            }
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
                if (!hnpmHidden) { HNPMShowCards(); HNPMSetIslandContentHidden(NO, @"重试"); }
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
        HNPMSetIslandContentHidden(YES, @"隐藏");
    } else {
        HNPMRestoreWithRetries();
        HNPMSetIslandContentHidden(NO, @"恢复");
    }
    HNPMAppendLog([NSString stringWithFormat:@"%@ → 状态=%@",
                   reason, hide ? @"已隐藏(音乐继续)" : @"已恢复显示"]);
}

// 0.5 秒轮询: 隐藏期间检测"暂停→继续播放"; 维持岛内媒体内容隐藏(系统重开就再藏)
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
                            HNPMSetIslandContentHidden(YES, @"轮询");
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
static void HNPMWalkIvarsFull(id obj, NSString *tag);
static void HNPMWalkIvars(id obj, NSString *tag);

%group HNPMIslandElement
%hook _SAUIElementViewContentView
- (void)didMoveToWindow {
    %orig;
    @try {
        if (!self.window) return;
        [hnpmIslandViews addObject:self];
        HNPMLogThrottled([NSString stringWithFormat:@"[灵动岛] 元素内容登记 frame=%@",
                          NSStringFromCGRect(self.frame)]);
        // v0.0.45: 隐藏期间系统新建的媒体内容 → 延迟 0.3s 待宽度稳定后判定并保持隐藏
        if (hnpmHidden) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                @try {
                    if (hnpmHidden && self.window && HNPMIsIslandMediaView(self)) self.hidden = YES;
                } @catch (NSException *e) {}
            });
        }
        // 一次性: 翻内容视图的属性链找元素模型
        static BOOL walked = NO;
        if (!walked) {
            walked = YES;
            HNPMWalkIvarsFull(self, @"岛内容视图");
            Class c = [self class];
            int depth = 0;
            while (c && depth < 5) {
                unsigned int ic = 0;
                Ivar *ivs = class_copyIvarList(c, &ic);
                for (unsigned int i = 0; i < ic; i++) {
                    const char *ty = ivar_getTypeEncoding(ivs[i]);
                    if (!ty || ty[0] != '@') continue;
                    id v = object_getIvar(self, ivs[i]);
                    if (!v) continue;
                    NSString *cls = NSStringFromClass([v class]);
                    if ([cls containsString:@"Element"] || [cls containsString:@"Content"]
                        || [cls containsString:@"Model"] || [cls containsString:@"Item"]
                        || [cls containsString:@"Representation"]) {
                        NSString *desc = [v description];
                        if ([desc length] > 400) desc = [desc substringToIndex:400];
                        HNPMAppendLog([NSString stringWithFormat:@"[元素模型] 属性 %s(%@): %@",
                                       ivar_getName(ivs[i]), cls, desc]);
                        HNPMWalkIvarsFull(v, [NSString stringWithFormat:@"元素模型(%s)", ivar_getName(ivs[i])]);
                    }
                }
                free(ivs);
                c = [c superclass];
                depth++;
            }
            HNPMAppendLog(@"[元素模型] 完成");
        }
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
        // v0.0.45: 隐藏期间系统新建的媒体内容 → 延迟 0.3s 待宽度稳定后判定并保持隐藏
        if (hnpmHidden) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                @try {
                    if (hnpmHidden && self.window && HNPMIsIslandMediaView(self)) self.hidden = YES;
                } @catch (NSException *e) {}
            });
        }
    } @catch (NSException *e) {}
}
%end
%end

#pragma mark - 入口

__attribute__((constructor)) static void HNPMRawCtor(void) {
    HNPMAppendLog(@"v0.0.45: dylib 构造函数已执行(dyld 加载成功)");
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

// 侦察: 通过 SBLockScreenManager 单例(免钩子)找 Aperture 控制器实例及元素存储
static void HNPMReconLockManager(void) {
    @try {
        Class m = NSClassFromString(@"SBLockScreenManager");
        if (!m) { HNPMAppendLog(@"[锁管理] SBLockScreenManager 不存在"); return; }
        id inst = nil;
        SEL sh = NSSelectorFromString(@"sharedInstance");
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        if ([m respondsToSelector:sh]) inst = [(id)m performSelector:sh];
#pragma clang diagnostic pop
        HNPMAppendLog([NSString stringWithFormat:@"[锁管理] 单例=%@", inst]);
        if (!inst) return;
        id apertureCtrl = nil;
        unsigned int ic = 0;
        Ivar *ivs = class_copyIvarList([inst class], &ic);
        for (unsigned int i = 0; i < ic; i++) {
            const char *ty = ivar_getTypeEncoding(ivs[i]);
            if (!ty || ty[0] != '@') continue;
            id v = object_getIvar(inst, ivs[i]);
            if (!v) continue;
            NSString *cls = NSStringFromClass([v class]);
            if ([cls containsString:@"Aperture"] || [cls containsString:@"LockElement"]) {
                HNPMAppendLog([NSString stringWithFormat:@"[锁管理] 属性 %s = %@", ivar_getName(ivs[i]), cls]);
                if ([cls containsString:@"Aperture"] && !apertureCtrl) apertureCtrl = v;
            }
        }
        free(ivs);
        if (!apertureCtrl) { HNPMAppendLog(@"[锁管理] 未找到 Aperture 对象引用"); return; }
        HNPMAppendLog([NSString stringWithFormat:@"[锁管理] 岛控制器实例=%@", apertureCtrl]);
        if ([apertureCtrl respondsToSelector:NSSelectorFromString(@"_currentFirstElement")]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id el = [apertureCtrl performSelector:NSSelectorFromString(@"_currentFirstElement")];
#pragma clang diagnostic pop
            HNPMAppendLog([NSString stringWithFormat:@"[锁管理] 当前元素=%@",
                           el ? NSStringFromClass([el class]) : @"(nil)"]);
        }
        unsigned int cc = 0;
        Ivar *civs = class_copyIvarList([apertureCtrl class], &cc);
        for (unsigned int i = 0; i < cc; i++) {
            const char *ty = ivar_getTypeEncoding(civs[i]);
            if (!ty || ty[0] != '@') continue;
            id v = object_getIvar(apertureCtrl, civs[i]);
            if (!v) continue;
            NSString *cls = NSStringFromClass([v class]);
            if ([cls containsString:@"Element"] || [cls containsString:@"Array"] || [cls containsString:@"Dictionary"] || [cls containsString:@"Set"]) {
                HNPMAppendLog([NSString stringWithFormat:@"[锁管理] 控制器属性 %s = %@ (%@)",
                               ivar_getName(civs[i]), cls, [v description]]);
            }
        }
        free(civs);
    } @catch (NSException *e) {
        HNPMAppendLog([NSString stringWithFormat:@"[锁管理] 侦察异常: %@", e.reason]);
    }
}

// 通用: 只读遍历对象属性, 记录含关键类名的引用
static void HNPMWalkIvars(id obj, NSString *tag) {
    @try {
        unsigned int ic = 0;
        Ivar *ivs = class_copyIvarList([obj class], &ic);
        for (unsigned int i = 0; i < ic; i++) {
            const char *ty = ivar_getTypeEncoding(ivs[i]);
            if (!ty || ty[0] != '@') continue;
            id v = object_getIvar(obj, ivs[i]);
            if (!v) continue;
            NSString *cls = NSStringFromClass([v class]);
            if ([cls containsString:@"Aperture"] || [cls containsString:@"LockElement"]
                || [cls containsString:@"Magician"] || [cls containsString:@"Controller"]
                || [cls containsString:@"Provider"] || [cls containsString:@"Element"])
                HNPMAppendLog([NSString stringWithFormat:@"[%@] 属性 %s = %@", tag, ivar_getName(ivs[i]), cls]);
        }
        free(ivs);
    } @catch (NSException *e) {}
}

// 侦察: 从岛窗口/锁元素提供者侧免钩子定位 Aperture 控制器实例
static void HNPMReconWindows(void) {
    @try {
        Class m = NSClassFromString(@"SBLockScreenManager");
        id mgr = nil;
        SEL sh = NSSelectorFromString(@"sharedInstance");
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        if (m && [m respondsToSelector:sh]) mgr = [(id)m performSelector:sh];
#pragma clang diagnostic pop
        if (mgr) {
            unsigned int ic = 0;
            Ivar *ivs = class_copyIvarList([mgr class], &ic);
            for (unsigned int i = 0; i < ic; i++) {
                const char *ty = ivar_getTypeEncoding(ivs[i]);
                if (!ty || ty[0] != '@') continue;
                id v = object_getIvar(mgr, ivs[i]);
                if (v && [NSStringFromClass([v class]) containsString:@"LockElement"]) {
                    HNPMWalkIvars(v, @"锁元素");
                }
            }
            free(ivs);
        }
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            NSString *wn = NSStringFromClass([w class]);
            if (![wn containsString:@"Aperture"]) continue;
            HNPMAppendLog([NSString stringWithFormat:@"[岛窗口] %@", wn]);
            HNPMWalkIvars(w, @"岛窗口");
            HNPMWalkIvars([w rootViewController], @"岛窗口VC");
            if ([w respondsToSelector:NSSelectorFromString(@"rootViewIfLoaded")]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                HNPMWalkIvars([w performSelector:NSSelectorFromString(@"rootViewIfLoaded")], @"岛窗口根视图");
#pragma clang diagnostic pop
            }
        }
        HNPMAppendLog(@"[岛窗口] 遍历完成");
    } @catch (NSException *e) {
        HNPMAppendLog([NSString stringWithFormat:@"[岛窗口] 侦察异常: %@", e.reason]);
    }
}

// 通用: 完整遍历对象属性(含父类链, 每个对象属性都记)
static void HNPMWalkIvarsFull(id obj, NSString *tag) {
    @try {
        if (!obj) return;
        Class c = [obj class];
        int depth = 0;
        while (c && depth < 5) {
            unsigned int ic = 0;
            Ivar *ivs = class_copyIvarList(c, &ic);
            for (unsigned int i = 0; i < ic; i++) {
                const char *ty = ivar_getTypeEncoding(ivs[i]);
                if (!ty || ty[0] != '@') continue;
                id v = object_getIvar(obj, ivs[i]);
                if (!v) continue;
                NSString *cls = NSStringFromClass([v class]);
                if ([cls hasPrefix:@"NS"] && ![cls containsString:@"Array"] && ![cls containsString:@"Dictionary"]
                    && ![cls containsString:@"Set"] && ![cls containsString:@"Mutable"]) continue;
                HNPMAppendLog([NSString stringWithFormat:@"[%@] %@ %s = %@",
                               tag, NSStringFromClass(c), ivar_getName(ivs[i]), cls]);
            }
            free(ivs);
            c = [c superclass];
            depth++;
        }
    } @catch (NSException *e) {}
}

// 深挖: 元素宿主与内容VC的第二层属性
static void HNPMReconDeep(void) {
    @try {
        Class m = NSClassFromString(@"SBLockScreenManager");
        id mgr = nil;
        SEL sh = NSSelectorFromString(@"sharedInstance");
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        if (m && [m respondsToSelector:sh]) mgr = [(id)m performSelector:sh];
#pragma clang diagnostic pop
        if (mgr) {
            unsigned int ic = 0;
            Ivar *ivs = class_copyIvarList([mgr class], &ic);
            for (unsigned int i = 0; i < ic; i++) {
                const char *ty = ivar_getTypeEncoding(ivs[i]);
                if (!ty || ty[0] != '@') continue;
                id v = object_getIvar(mgr, ivs[i]);
                if (!v || ![NSStringFromClass([v class]) containsString:@"LockElement"]) continue;
                unsigned int jc = 0;
                Ivar *jvs = class_copyIvarList([v class], &jc);
                for (unsigned int j = 0; j < jc; j++) {
                    const char *ty2 = ivar_getTypeEncoding(jvs[j]);
                    if (!ty2 || ty2[0] != '@') continue;
                    id w = object_getIvar(v, jvs[j]);
                    if (!w) continue;
                    NSString *wcls = NSStringFromClass([w class]);
                    if ([wcls containsString:@"ViewController"] || [wcls containsString:@"Provider"]) {
                        HNPMWalkIvarsFull(w, [NSString stringWithFormat:@"深挖(%s)", ivar_getName(jvs[j])]);
                    }
                }
                free(jvs);
            }
            free(ivs);
        }
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (![NSStringFromClass([w class]) containsString:@"Aperture"]) continue;
            id rvc = [w rootViewController];
            if (!rvc) continue;
            unsigned int kc = 0;
            Ivar *kvs = class_copyIvarList([rvc class], &kc);
            for (unsigned int k = 0; k < kc; k++) {
                const char *ty = ivar_getTypeEncoding(kvs[k]);
                if (!ty || ty[0] != '@') continue;
                id c = object_getIvar(rvc, kvs[k]);
                if (c && [NSStringFromClass([c class]) containsString:@"ViewController"]) {
                    HNPMWalkIvarsFull(c, [NSString stringWithFormat:@"窗口内容VC(%s)", ivar_getName(kvs[k])]);
                }
            }
            free(kvs);
        }
        HNPMAppendLog(@"[深挖] 完成");
    } @catch (NSException *e) {
        HNPMAppendLog([NSString stringWithFormat:@"[深挖] 异常: %@", e.reason]);
    }
}

%ctor {
    @autoreleasepool {
        HNPMAppendLog(@"v0.0.43: logos %ctor 进入");

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
        HNPMReconApertureManager();
        HNPMReconApertureClasses();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            HNPMReconApertureController();
            HNPMReconLockManager();
            HNPMReconWindows();
            HNPMReconDeep();
        });
        HNPMAppendLog(@"v0.0.43: %ctor 正常完成");
    }
}
