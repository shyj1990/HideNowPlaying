// HideNowPlaying v0.0.51 — 修复恢复侧: 解除抑制必须触发控制器重评估
//
// v0.0.50 实测: 隐藏侧成功(信号图标原生回归), 恢复侧失败(黑色长胶囊)。
//   根因: 元素被抑制后 _currentFirstElement 变 nil → HNPMSetElementSuppression 提前
//   return, _reevaluateSystemApertureCompleteSuppression 从未执行 → 恢复时模型层仍处
//   抑制态, 系统不重新驱动媒体内容管线 → 只剩黑壳长胶囊。
// v0.0.51: ①钩 elementIdentifier 跟踪 NowPlaying 元素实例(抑制后唯一稳定定位来源);
//   ②解除时对跟踪表全部元素置 requiresSuppressionFromSystemAperture=NO + 必定触发重评估;
//   ③恢复 +1s/+3s 重申解除; ④恢复 +3s 元素态+树倾诊断; ⑤恢复命中时抖动岛窗口逼重合成。
// 保持不变: 策略钩子(5个) + 全家桶视觉兜底(v0.0.47) + 0.5s 轮询 + 恢复重试。
//
// 日志: /var/mobile/Documents/HideNowPlaying.log   紧急开关: /var/mobile/Documents/HideNowPlaying.off

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
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
static NSHashTable *hnpmElementTable = nil;  // 弱引用: 见过的 NowPlaying 岛元素(抑制后 _currentFirstElement 变 nil, 此表是唯一稳定定位来源)
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

// v0.0.46: 倾倒两个 Aperture 窗口的完整视图树(类名/frame/hidden/alpha)
// 目的: 定位"封面/波纹画面到底渲染在哪些视图"——v0.0.45 藏了 SAUI 视图但画面仍可见
static void HNPMDumpApertureTrees(NSString *tag) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            int winIdx = 0;
            for (UIWindow *w in [UIApplication sharedApplication].windows) {
                if (![NSStringFromClass([w class]) containsString:@"Aperture"]) continue;
                winIdx++;
                HNPMAppendLog([NSString stringWithFormat:@"[树倾%@] 窗口%d 开始 %@",
                               tag, winIdx, NSStringFromClass([w class])]);
                NSMutableArray *stack = [NSMutableArray arrayWithObject:w];
                NSMutableArray *depths = [NSMutableArray arrayWithObject:@0];
                int lines = 0, guard = 0;
                while (stack.count > 0 && guard++ < 900 && lines < 160) {
                    UIView *v = stack.firstObject;
                    int d = [depths.firstObject intValue];
                    [stack removeObjectAtIndex:0];
                    [depths removeObjectAtIndex:0];
                    if (!v) continue;
                    if (v != w) {
                        lines++;
                        NSMutableString *indent = [NSMutableString string];
                        for (int i = 0; i < d; i++) [indent appendString:@"  "];
                        HNPMAppendLog([NSString stringWithFormat:@"[树倾%@] %@%@ f=%@ h=%d a=%.2f c=%d",
                                       tag, indent, NSStringFromClass([v class]),
                                       NSStringFromCGRect(v.frame), v.isHidden ? 1 : 0, v.alpha,
                                       v.layer.contents ? 1 : 0]);
                    }
                    NSArray *subs = [v subviews];
                    NSUInteger cnt = subs.count;
                    for (NSUInteger i = 0; i < cnt; i++) {
                        [stack insertObject:subs[cnt - 1 - i] atIndex:0];
                        [depths insertObject:@(d + 1) atIndex:0];
                    }
                }
                if (lines >= 160)
                    HNPMAppendLog([NSString stringWithFormat:@"[树倾%@] 窗口%d 行数截断", tag, winIdx]);
                else
                    HNPMAppendLog([NSString stringWithFormat:@"[树倾%@] 窗口%d 结束 共%d行", tag, winIdx, lines]);
            }
        } @catch (NSException *e) {}
    });
}

// v0.0.48: 模型级侦察+实验 — 递归定位 SBSystemApertureController 实例(免钩子),
// stateDump 前后对比; 实验: 调 restrictSystemApertureToDefaultLayoutWithReason:
// 请求系统把岛限制在默认布局(待机短胶囊+信号图标) = 模型级抑制媒体元素;
// 恢复时调 restrict(nil) + _reevaluateSystemApertureCompleteSuppression 尝试解除
static id HNPMFindApertureControllerInVC(UIViewController *vc, int depth) {
    @try {
        if (!vc || depth > 4) return nil;
        if ([NSStringFromClass([vc class]) containsString:@"Aperture"]) {
            unsigned int ic = 0;
            Ivar *ivs = class_copyIvarList([vc class], &ic);
            for (unsigned int i = 0; i < ic; i++) {
                const char *ty = ivar_getTypeEncoding(ivs[i]);
                if (!ty || ty[0] != '@') continue;
                id v = object_getIvar(vc, ivs[i]);
                if (v && [NSStringFromClass([v class]) isEqualToString:@"SBSystemApertureController"]) {
                    free(ivs);
                    return v;
                }
            }
            free(ivs);
        }
        for (UIViewController *child in vc.childViewControllers) {
            id r = HNPMFindApertureControllerInVC(child, depth + 1);
            if (r) return r;
        }
        unsigned int ic2 = 0;
        Ivar *ivs2 = class_copyIvarList([vc class], &ic2);
        for (unsigned int i = 0; i < ic2; i++) {
            const char *ty = ivar_getTypeEncoding(ivs2[i]);
            if (!ty || ty[0] != '@') continue;
            id v = object_getIvar(vc, ivs2[i]);
            if (v && [v isKindOfClass:[UIViewController class]]) {
                id r = HNPMFindApertureControllerInVC(v, depth + 1);
                if (r) { free(ivs2); return r; }
            }
        }
        free(ivs2);
    } @catch (NSException *e) {}
    return nil;
}

static id HNPMIslandController(void) {
    @try {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (![NSStringFromClass([w class]) containsString:@"Aperture"]) continue;
            UIViewController *rvc = w.rootViewController;
            if (!rvc) continue;
            id c = HNPMFindApertureControllerInVC(rvc, 0);
            if (c) return c;
        }
    } @catch (NSException *e) {}
    return nil;
}

// v0.0.50: 模型级抑制 — 方法表侦察实锤 SBSystemApertureSceneElement 自带"要求被岛抑制"策略
// (requiresSuppressionFromSystemAperture + shouldSuppressElementWhile* 四查询点)。钩之: 隐藏期
// 仅对 NowPlaying 元素返回 YES → 系统自己撤下媒体元素 → 回默认布局(信号图标原生回归);
// 恢复期还原。另在 hide/restore 时直接置属性并调 _reevaluateSystemApertureCompleteSuppression
// 触发即时重评估(双保险)。
static BOOL HNPMIsNowPlayingElement(id el) {
    @try {
        if (!el) return NO;
        SEL gi = NSSelectorFromString(@"elementIdentifier");
        if (![el respondsToSelector:gi]) return NO;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id v = [el performSelector:gi];
#pragma clang diagnostic pop
        return [v isKindOfClass:[NSString class]] && [(NSString *)v containsString:@"NowPlaying"];
    } @catch (NSException *e) { return NO; }
}

static void HNPMSetElementSuppression(BOOL suppress, NSString *tag) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            NSMutableArray *targets = [NSMutableArray array];
            // 跟踪表(元素被抑制后 _currentFirstElement 会变 nil, 跟踪表是唯一稳定来源)
            if (hnpmElementTable) {
                NSArray *snap = nil;
                @synchronized(hnpmElementTable) { snap = [[hnpmElementTable allObjects] copy]; }
                for (id e in snap) {
                    if (e && HNPMIsNowPlayingElement(e) && ![targets containsObject:e]) [targets addObject:e];
                }
            }
            // 兜底: 控制器当前首元素
            id ctrl = HNPMIslandController();
            if (ctrl) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                SEL fe = NSSelectorFromString(@"_currentFirstElement");
                if ([ctrl respondsToSelector:fe]) {
                    id el = [ctrl performSelector:fe];
                    if (el && HNPMIsNowPlayingElement(el) && ![targets containsObject:el]) [targets addObject:el];
                }
#pragma clang diagnostic pop
            }
            SEL rs = NSSelectorFromString(@"setRequiresSuppressionFromSystemAperture:");
            int set = 0;
            for (id el in targets) {
                @try {
                    if ([el respondsToSelector:rs]) {
                        void (*setSup)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))objc_msgSend;
                        setSup(el, rs, suppress);
                        set++;
                    }
                } @catch (NSException *e) {}
            }
            // v0.0.50 教训: 无论是否拿到元素, 重评估都必须触发 — 否则模型层永远停在抑制态
            int ree = 0;
            if (ctrl) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                SEL re = NSSelectorFromString(@"_reevaluateSystemApertureCompleteSuppression");
                if ([ctrl respondsToSelector:re]) { [ctrl performSelector:re]; ree = 1; }
#pragma clang diagnostic pop
            }
            HNPMAppendLog([NSString stringWithFormat:@"[抑制%@] 目标%d 置%d 重评估%d 控制器%@",
                           tag, (int)targets.count, set, ree, ctrl ? @"已定位" : @"未定位"]);
        } @catch (NSException *e) {
            HNPMAppendLog([NSString stringWithFormat:@"[抑制%@] 异常: %@", tag, e.reason]);
        }
    });
}

// 诊断: 倾倒跟踪表中 NowPlaying 元素的当前状态(isActivated 等)
static void HNPMLogElementState(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (!hnpmElementTable) return;
            NSArray *snap = nil;
            @synchronized(hnpmElementTable) { snap = [[hnpmElementTable allObjects] copy]; }
            int i = 0;
            for (id e in snap) {
                if (!e || !HNPMIsNowPlayingElement(e)) continue;
                i++;
                NSString *desc = [e description];
                if (desc.length > 300) desc = [desc substringToIndex:300];
                HNPMAppendLog([NSString stringWithFormat:@"[元素态%d] %@", i, desc]);
            }
            HNPMAppendLog([NSString stringWithFormat:@"[元素态] 共%d个", i]);
        } @catch (NSException *e) {}
    });
}

// 尺寸带: 媒体元素的外壳/容器/快照视图都落在 宽150~350 × 高30~80
// (幕帘125宽、待机元素126宽、活动小图标22~30宽、全屏容器393宽 都不在带内)
static BOOL HNPMInMediaSizeBand(CGSize size) {
    return (size.width >= 150.0 && size.width <= 350.0
            && size.height >= 30.0 && size.height <= 80.0);
}

// v0.0.47: "媒体元素全家桶"隐藏 —— 内容视图 + 其全部祖先 + 尺寸带内与媒体 frame 重叠的外壳
// 恢复时同一套判定反向点亮; 只对内容视图做原位重新挂载(抗黑壳)
static void HNPMSetIslandContentHidden(BOOL hide, NSString *tag) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            NSMutableArray *t1 = [NSMutableArray array];       // 媒体内容视图(两类)
            NSMutableArray *t1Frames = [NSMutableArray array]; // 内容视图窗口坐标(外扩12pt)
            NSMutableSet *family = [NSMutableSet set];         // 内容视图的全部祖先
            // 第一遍: 收集媒体内容视图 + 祖先链 + frame
            for (UIWindow *w in [UIApplication sharedApplication].windows) {
                if (![NSStringFromClass([w class]) containsString:@"Aperture"]) continue;
                NSMutableArray *stack = [NSMutableArray arrayWithObject:w];
                int guard = 0;
                while (stack.count > 0 && guard++ < 800) {
                    UIView *v = stack.firstObject;
                    [stack removeObjectAtIndex:0];
                    if (!v) continue;
                    [stack addObjectsFromArray:v.subviews];
                    if (!HNPMIsIslandMediaView(v)) continue;
                    [t1 addObject:v];
                    [t1Frames addObject:[NSValue valueWithCGRect:CGRectInset([v convertRect:v.bounds toView:nil], -12, -12)]];
                    for (UIView *p = v.superview; p && p != w; p = p.superview) [family addObject:p];
                }
            }
            int n = 0, kicked = 0, shells = 0;
            NSMutableArray *descs = [NSMutableArray array];
            // 第二遍: 应用(内容视图 / 祖先 / 与媒体 frame 重叠的尺寸带外壳)
            for (UIWindow *w in [UIApplication sharedApplication].windows) {
                if (![NSStringFromClass([w class]) containsString:@"Aperture"]) continue;
                NSMutableArray *stack = [NSMutableArray arrayWithObject:w];
                int guard = 0;
                while (stack.count > 0 && guard++ < 800) {
                    UIView *v = stack.firstObject;
                    [stack removeObjectAtIndex:0];
                    if (!v) continue;
                    [stack addObjectsFromArray:v.subviews];
                    BOOL isT1 = HNPMIsIslandMediaView(v);
                    BOOL linked = isT1 || [family containsObject:v];
                    if (!linked && HNPMInMediaSizeBand(v.frame.size)) {
                        CGRect wf = [v convertRect:v.bounds toView:nil];
                        for (NSValue *fv in t1Frames) {
                            if (CGRectIntersectsRect(wf, [fv CGRectValue])) { linked = YES; shells++; break; }
                        }
                    }
                    if (!linked) continue;
                    if (hide) {
                        if (!v.isHidden) {
                            v.hidden = YES;
                            n++;
                            if (descs.count < 6)
                                [descs addObject:[NSString stringWithFormat:@"%@ %@",
                                                  NSStringFromClass([v class]), NSStringFromCGRect(v.frame)]];
                        }
                    } else if (v.isHidden || v.alpha < 0.05) {
                        v.hidden = NO;
                        v.alpha = 1.0;
                        n++;
                        // 内容视图原位重新挂载(摘下再装回) → 逼远程渲染管线重新 attach, 抗黑壳
                        if (isT1) {
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
            }
            // v0.0.51: 恢复且确实点亮了东西时, 轻微抖动岛窗口逼系统重新合成画面(v0.0.44 抗黑壳老招)
            if (!hide && (n > 0 || kicked > 0)) {
                for (UIWindow *w in [UIApplication sharedApplication].windows) {
                    if (![NSStringFromClass([w class]) containsString:@"Aperture"]) continue;
                    @try {
                        CGRect f = w.frame;
                        w.frame = CGRectOffset(f, 0.5, 0);
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                                       dispatch_get_main_queue(), ^{
                            @try { w.frame = f; } @catch (NSException *e) {}
                        });
                    } @catch (NSException *e) {}
                }
            }
            if (n > 0 || [tag isEqualToString:@"隐藏"] || [tag isEqualToString:@"恢复"]) {
                NSString *kick = kicked > 0 ? [NSString stringWithFormat:@"(重新挂载 %d)", kicked] : @"";
                HNPMAppendLog([NSString stringWithFormat:@"[岛内] %@ 命中 %d 个→%@%@ 外壳%d %@",
                               tag, n, hide ? @"隐藏" : @"显示", kick, shells,
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
    NSArray *delays = @[@0.0, @0.5, @1.0, @2.0, @3.5, @5.0, @7.0];
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
        // v0.0.51: 模型级抑制(置属性+触发重评估, 应即时生效; +2s 重申兜底)
        HNPMSetElementSuppression(YES, @"·隐");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try {
                if (hnpmHidden) HNPMSetElementSuppression(YES, @"·隐2");
            } @catch (NSException *e) {}
        });
        for (NSNumber *d in @[@3.0, @20.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)([d doubleValue] * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                @try {
                    if (hnpmHidden) {
                        HNPMLogElementState();
                        HNPMDumpApertureTrees([NSString stringWithFormat:@"+%@", d]);
                    }
                } @catch (NSException *e) {}
            });
        }
    } else {
        // v0.0.51: 先解除模型级抑制并触发重评估 → 系统重新呈现媒体元素(内容管线复活);
        // 视图点亮立即一次 + 延迟重试, 避免把系统尚未重建的陈旧视图提前点亮成黑壳
        HNPMSetElementSuppression(NO, @"·解");
        HNPMRestoreWithRetries();
        HNPMSetIslandContentHidden(NO, @"恢复");
        // +1s/+3s 重申解除(防竞态) + 恢复期元素态/树倾诊断
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try {
                if (!hnpmHidden) {
                    HNPMSetElementSuppression(NO, @"·解2");
                    HNPMSetIslandContentHidden(NO, @"恢复2");
                }
            } @catch (NSException *e) {}
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try {
                if (!hnpmHidden) {
                    HNPMSetElementSuppression(NO, @"·解3");
                    HNPMSetIslandContentHidden(NO, @"恢复3");
                    HNPMLogElementState();
                    HNPMDumpApertureTrees(@"恢复+3");
                }
            } @catch (NSException *e) {}
        });
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
    HNPMAppendLog(@"v0.0.51: dylib 构造函数已执行(dyld 加载成功)");
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

// v0.0.50/51: 岛元素抑制策略钩子 — 隐藏期让系统把 NowPlaying 元素当作"应被抑制",
// 沿用苹果自己的抑制机制 → 岛回默认布局(待机短胶囊+信号图标), 活动元素不受影响。
// v0.0.51 另钩 elementIdentifier 跟踪元素实例(元素被抑制后 _currentFirstElement 变 nil)
%group HNPMIslandSuppression
%hook SBSystemApertureSceneElement

// v0.0.51: 元素跟踪 — 记录见过的 NowPlaying 元素(弱引用), 供解除抑制时定位
- (NSString *)elementIdentifier {
    NSString *v = %orig;
    @try {
        if (hnpmElementTable && [v isKindOfClass:[NSString class]]
            && [(NSString *)v containsString:@"NowPlaying"]) {
            @synchronized(hnpmElementTable) {
                if (![hnpmElementTable containsObject:self]) [hnpmElementTable addObject:self];
            }
        }
    } @catch (NSException *e) {}
    return v;
}

- (BOOL)requiresSuppressionFromSystemAperture {
    if (hnpmHidden && HNPMIsNowPlayingElement(self)) return YES;
    return %orig;
}

- (BOOL)shouldSuppressElementWhileOnCoversheet {
    if (hnpmHidden && HNPMIsNowPlayingElement(self)) return YES;
    return %orig;
}

- (BOOL)shouldSuppressElementWhilePresentingNoAppsOrScenes {
    if (hnpmHidden && HNPMIsNowPlayingElement(self)) return YES;
    return %orig;
}

- (BOOL)shouldSuppressElementWhilePresentingAppWithBundleId:(id)bundleId {
    if (hnpmHidden && HNPMIsNowPlayingElement(self)) return YES;
    return %orig;
}

- (BOOL)shouldSuppressElementWhilePresentingSceneWithIdentifier:(id)sceneId {
    if (hnpmHidden && HNPMIsNowPlayingElement(self)) return YES;
    return %orig;
}

%end
%end

%ctor {
    @autoreleasepool {
        HNPMAppendLog(@"v0.0.51: logos %ctor 进入");

        if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/Documents/HideNowPlaying.off"]) {
            HNPMAppendLog(@"检测到开关文件 HideNowPlaying.off, 不注册任何 hook");
            return;
        }

        hnpmCardCells = [NSHashTable weakObjectsHashTable];
        hnpmCardContents = [NSHashTable weakObjectsHashTable];
        hnpmIslandViews = [NSHashTable weakObjectsHashTable];
        hnpmElementTable = [NSHashTable weakObjectsHashTable];
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
        if (objc_getClass("SBSystemApertureSceneElement"))   { %init(HNPMIslandSuppression); HNPMAppendLog(@"hook 已注册: 岛元素抑制策略+元素跟踪(NowPlaying)"); }
        HNPMAppendLog(@"v0.0.51: %ctor 正常完成");
    }
}
