// HideNowPlaying v0.0.59 — 省电优化第四步(稳态档 1.0s → 1.5s)
//
// v0.0.58 结论: ①被动监听死路 — dlsym 在 SpringBoard 内拿不到 Darwin 通知中心
//   (0.0.54"未注册"同源, 两次实锤, iOS17 此路径不通), 监听代码已整体移除;
//   ②诊断行实锤: 注册符号在 MediaRemote 内存在 → 0.0.54 当年注册调用确实执行过。
//   两凶手(注册调用 / GCD定时器)各自定罪完毕, 均永久关闭。
// 本版: 轮询机制/代码与 v0.0.57 完全一致, 仅稳态档 1.0s → 1.5s(稳态唤醒再省 1/3)。
//   恢复检测靠稳态轮询, 暂停→播放恢复延迟 ≤~2s 属预期; 1.5s 验证稳定后下版再试 2.0s。
//
// 日志: /var/mobile/Documents/HideNowPlaying.log   紧急开关: /var/mobile/Documents/HideNowPlaying.off

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <math.h>
#import <stdlib.h>

#pragma mark - 前置声明

static void HNPMSetHidden(BOOL hide, NSString *reason);
static void HNPMStartRestorePolling(void);

#pragma mark - 日志

static void HNPMAppendLog(NSString *text) {
    @try {
        NSString *path = @"/var/mobile/Documents/HideNowPlaying.log";
        // v0.0.52: 日志上限 256KB, 超限清空重写(正式版只记关键事件, 不会再膨胀到 MB 级)
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
        if (attrs && [attrs fileSize] > 256 * 1024) [fm removeItemAtPath:path error:nil];
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], text];
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
static CFAbsoluteTime hnpmFastUntil = 0;     // 此时刻之前轮询用快节奏(0.5s); 稳态慢节奏(1s)省电
static NSTimer *hnpmPollTimer = nil;         // 自适应轮询定时器(纯 NSTimer — v0.0.56 实锤 GCD 定时器独立致卡死, 永久弃用)
static BOOL hnpmSteadyLogged = NO;           // 本次隐藏期"转入稳态"只记一行
static void HNPMBumpFastPhase(void) { hnpmFastUntil = CFAbsoluteTimeGetCurrent() + 10.0; }

#pragma mark - MediaRemote

// v0.0.55: 已移除 v0.0.54 新增的 MRMediaRemoteRegisterForNowPlayingNotifications + Darwin
// 通知注册 — 真机实测: 每次隐藏后系统媒体控制链路被搅乱(CC 播放控制失效/音乐App被看门狗杀/
// 其他App卡死), v0.0.51~53 无此调用六轮零问题。播放/暂停检测退回 0.5s 轮询。

typedef void (*HNPMGetInfoFunc)(dispatch_queue_t, void (^)(CFDictionaryRef));
static HNPMGetInfoFunc hnpmGetInfo = NULL;

// 查一次正在播放信息并喂给"暂停→继续播放"状态机(隐藏期轮询每跳调用)
static void HNPMQueryNowPlayingOnce(void) {
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
}

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

// v0.0.54: 归属结果缓存(关联对象) — 稳态轮询反复分类同一批视图, 不必每次重走 ivar
// (只缓存非空结果: 视图刚创建还没挂到元素上的瞬时不缓存, 避免把"查不到"固化成误判)
static void *kHNPMElementIdKey = &kHNPMElementIdKey;

// v0.0.53: 沿视图链反查元素归属 — 找挂在链上视图/其ivar里的元素模型对象, 返回 elementIdentifier
// (只向上找6层、每层查3级父类的ivar, 避免被高层共享容器里无关的元素引用污染)
static NSString *HNPMElementIdForView(UIView *v) {
    @try {
        id cached = objc_getAssociatedObject(v, kHNPMElementIdKey);
        if ([cached isKindOfClass:[NSString class]]) return cached;
        SEL gi = NSSelectorFromString(@"elementIdentifier");
        int depth = 0;
        for (UIView *p = v; p && depth < 6; p = p.superview, depth++) {
            if ([p respondsToSelector:gi]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                id r = [p performSelector:gi];
#pragma clang diagnostic pop
                if ([r isKindOfClass:[NSString class]]) {
                    objc_setAssociatedObject(v, kHNPMElementIdKey, r, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    return r;
                }
            }
            Class c = [p class];
            int cd = 0;
            while (c && cd < 3) {
                unsigned int ic = 0;
                Ivar *ivs = class_copyIvarList(c, &ic);
                for (unsigned int i = 0; i < ic; i++) {
                    const char *ty = ivar_getTypeEncoding(ivs[i]);
                    if (!ty || ty[0] != '@') continue;
                    id val = object_getIvar(p, ivs[i]);
                    if (!val || val == (id)p) continue;
                    if ([val isKindOfClass:[UIView class]] || [val isKindOfClass:[NSArray class]]
                        || [val isKindOfClass:[NSDictionary class]] || [val isKindOfClass:[NSSet class]]) continue;
                    if ([val respondsToSelector:gi]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                        id r = [val performSelector:gi];
#pragma clang diagnostic pop
                        if ([r isKindOfClass:[NSString class]]) {
                            free(ivs);
                            objc_setAssociatedObject(v, kHNPMElementIdKey, r, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                            return r;
                        }
                    }
                }
                free(ivs);
                c = [c superclass];
                cd++;
            }
        }
    } @catch (NSException *e) {}
    return nil;
}

// v0.0.53: 内容视图分类 — 0=不是内容视图 1=媒体(正在播放) 2=其他元素(通知/实时活动/待机小图标, 绝不能碰)
// eidOut 非空时带回元素归属(nil=链上找不到元素对象)
static int HNPMClassifyContentView(UIView *v, NSString **eidOut) {
    if (eidOut) *eidOut = nil;
    if (!v) return 0;
    NSString *cls = NSStringFromClass([v class]);
    if (![cls isEqualToString:@"_SAUIElementViewContentView"]
        && ![cls isEqualToString:@"_SAUIProvidedViewContainerView"]) return 0;
    NSString *eid = HNPMElementIdForView(v);
    if (eidOut) *eidOut = eid;
    if (eid && ![eid containsString:@"NowPlaying"]) return 2;   // 实锤别的元素 → 不碰
    if (v.bounds.size.width < 80.0) return 2;                    // 窄内容(待机小图标等)不按媒体处理
    return 1;                                                    // NowPlaying 实锤 或 找不到归属(按媒体兜底)
}

static BOOL HNPMIsIslandMediaView(UIView *v) {
    return HNPMClassifyContentView(v, NULL) == 1;
}

// v0.0.48: 模型级 — 递归定位 SBSystemApertureController 实例(免钩子)
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

// 尺寸带: 媒体元素的外壳/容器/快照视图都落在 宽150~350 × 高30~80
// (幕帘125宽、待机元素126宽、活动小图标22~30宽、全屏容器393宽 都不在带内)
static BOOL HNPMInMediaSizeBand(CGSize size) {
    return (size.width >= 150.0 && size.width <= 350.0
            && size.height >= 30.0 && size.height <= 80.0);
}

// v0.0.47: "媒体元素全家桶"隐藏 —— 内容视图 + 其祖先 + 尺寸带内与媒体 frame 重叠的外壳
// v0.0.53: 其他元素(通知/实时活动/待机小图标)的内容视图及其祖先记入"共享"集合, 绝不隐藏
//   (修复: 隐藏期来通知, 媒体视图被重挂进共享容器 → 连带藏掉状态栏/待机链 → 状态栏全空)
// 恢复时同一套判定反向点亮; 只对内容视图做原位重新挂载(抗黑壳)
static void HNPMSetIslandContentHidden(BOOL hide, NSString *tag) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            NSMutableArray *t1 = [NSMutableArray array];       // 媒体内容视图(两类)
            NSMutableArray *t1Frames = [NSMutableArray array]; // 内容视图窗口坐标(外扩12pt)
            NSMutableSet *family = [NSMutableSet set];         // 媒体内容视图的祖先(剔共享后)
            NSMutableSet *shared = [NSMutableSet set];         // 其他元素内容视图+祖先(绝不碰, 碰了状态栏会空)
            int others = 0, unknown = 0;
            // 第一遍: 分类所有内容视图 + 祖先链 + frame
            for (UIWindow *w in [UIApplication sharedApplication].windows) {
                if (![NSStringFromClass([w class]) containsString:@"Aperture"]) continue;
                NSMutableArray *stack = [NSMutableArray arrayWithObject:w];
                int guard = 0;
                while (stack.count > 0 && guard++ < 800) {
                    UIView *v = stack.firstObject;
                    [stack removeObjectAtIndex:0];
                    if (!v) continue;
                    [stack addObjectsFromArray:v.subviews];
                    NSString *eid = nil;
                    int kind = HNPMClassifyContentView(v, &eid);
                    if (kind == 0) continue;
                    if (kind == 2) {
                        // 其他元素: 自身+祖先全部记入共享保护
                        others++;
                        [shared addObject:v];
                        for (UIView *p = v.superview; p && p != w; p = p.superview) [shared addObject:p];
                        continue;
                    }
                    if (!eid) unknown++;
                    [t1 addObject:v];
                    [t1Frames addObject:[NSValue valueWithCGRect:CGRectInset([v convertRect:v.bounds toView:nil], -12, -12)]];
                    for (UIView *p = v.superview; p && p != w; p = p.superview) [family addObject:p];
                }
            }
            // 家族剔除共享(遍历里先后顺序不可靠, 统一剔除)
            for (UIView *s in shared) [family removeObject:s];
            int n = 0, kicked = 0, shells = 0;
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
                    if ([shared containsObject:v]) continue;   // 共享容器/其他元素内容: 绝不碰
                    BOOL isT1 = [t1 containsObject:v];
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
                HNPMAppendLog([NSString stringWithFormat:@"[岛内] %@ 命中 %d 个→%@%@ 外壳%d 其他%d 缺归属%d",
                               tag, n, hide ? @"隐藏" : @"显示", kick, shells, others, unknown]);
            }
            // v0.0.56: 隐藏期出现新命中(系统重挂了媒体视图) → 提速 10s 盯紧, 平时慢节奏省电
            if (hide && n > 0) HNPMBumpFastPhase();
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
        HNPMBumpFastPhase();  // 刚隐藏的 10s 内用快节奏盯紧过渡期
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
    } else {
        // v0.0.51: 先解除模型级抑制并触发重评估 → 系统重新呈现媒体元素(内容管线复活);
        // 视图点亮立即一次 + 延迟重试, 避免把系统尚未重建的陈旧视图提前点亮成黑壳
        HNPMSetElementSuppression(NO, @"·解");
        HNPMRestoreWithRetries();
        HNPMSetIslandContentHidden(NO, @"恢复");
        // +1s/+3s 重申解除(防竞态)
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
                }
            } @catch (NSException *e) {}
        });
    }
    HNPMAppendLog([NSString stringWithFormat:@"%@ → 状态=%@",
                   reason, hide ? @"已隐藏(音乐继续)" : @"已恢复显示"]);
}

// 自适应轮询(纯 NSTimer): 隐藏期间检测"暂停→继续播放" + 维持岛内媒体内容隐藏
// v0.0.57: 定时器机制与 v0.0.55 相同(0.5s NSTimer + NSRunLoopCommonModes); 稳态(非快相)用
//   setFireDate 把下一跳推迟到 1.0s 实现省电(唤醒减半), 快相保持 0.5s 不推迟。
//   不用 GCD dispatch_source — v0.0.56 实锤其独立致系统卡死(机理未明, 永久弃用)。
static void HNPMStartRestorePolling(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (hnpmPollTimer) return;
            hnpmSteadyLogged = NO;
            hnpmPollTimer = [NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
                @try {
                    if (!hnpmHidden) {
                        // 隐藏结束 → 停表(下次隐藏会重建)
                        if (hnpmPollTimer == t) { [hnpmPollTimer invalidate]; hnpmPollTimer = nil; }
                        return;
                    }
                    if (CFAbsoluteTimeGetCurrent() >= hnpmFastUntil) {
                        // 稳态: 推迟下一跳到 1.5s(v0.0.59: 1.0→1.5, 稳态唤醒再省 1/3; 机制仍是 NSTimer)
                        if (!hnpmSteadyLogged) {
                            HNPMAppendLog(@"[轮询] 转入稳态 1.5s");
                            hnpmSteadyLogged = YES;
                        }
                        [t setFireDate:[NSDate dateWithTimeIntervalSinceNow:1.5]];
                    }
                    // 快相: 不推迟, 保持 0.5s 原节奏
                    HNPMSetIslandContentHidden(YES, @"轮询");
                    HNPMQueryNowPlayingOnce();
                } @catch (NSException *e) {}
            }];
            [[NSRunLoop mainRunLoop] addTimer:hnpmPollTimer forMode:NSRunLoopCommonModes];
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
        // 只认"正在播放"卡片
        Class cellClass = NSClassFromString(@"NCNotificationListCell");
        UIView *p = gr.view;
        while (p && ![p isKindOfClass:cellClass]) p = p.superview;
        if (!p) return;
        BOOL accept = HNPMIsBottomMostMediaCell(p);
        // v0.0.54: 只在手势开始/判定翻转时记日志(原每个触摸事件都记, 一滑刷十几行)
        static BOOL hnpmLastPanAccept = NO;
        if (gr.state == UIGestureRecognizerStateBegan || accept != hnpmLastPanAccept) {
            hnpmLastPanAccept = accept;
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
                HNPMAppendLog([NSString stringWithFormat:@"[判定] 触摸单元格 myY=%.0f bestY=%.0f cells=%lu → %@",
                               myY, bestY, (unsigned long)hnpmCardCells.count,
                               accept ? @"接受(当作正在播放卡)" : @"拒绝(当作其他实时活动)"]);
            } @catch (NSException *e) {}
        }
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
        // v0.0.45: 隐藏期间系统新建的媒体内容 → 延迟 0.3s 待宽度稳定后判定并保持隐藏
        if (hnpmHidden) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                @try {
                    if (hnpmHidden && self.window && HNPMIsIslandMediaView(self)) { self.hidden = YES; HNPMBumpFastPhase(); }
                } @catch (NSException *e) {}
            });
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
        // v0.0.45: 隐藏期间系统新建的媒体内容 → 延迟 0.3s 待宽度稳定后判定并保持隐藏
        if (hnpmHidden) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                @try {
                    if (hnpmHidden && self.window && HNPMIsIslandMediaView(self)) { self.hidden = YES; HNPMBumpFastPhase(); }
                } @catch (NSException *e) {}
            });
        }
    } @catch (NSException *e) {}
}
%end
%end

#pragma mark - 入口

__attribute__((constructor)) static void HNPMRawCtor(void) {
    HNPMAppendLog(@"v0.0.59: dylib 构造函数已执行(dyld 加载成功)");
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
        HNPMAppendLog(@"v0.0.59: logos %ctor 进入");

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
            // 诊断留档: 注册符号存在但绝不调用(v0.0.54 头号嫌疑, 永久禁止; 0.0.58 实锤存在)
            void *regSym = dlsym(mr, "MRMediaRemoteRegisterForNowPlayingNotifications");
            HNPMAppendLog(hnpmGetInfo ? @"MediaRemote 已加载, 播放检测可用" : @"MediaRemote 已加载, 播放检测不可用");
            HNPMAppendLog(regSym ? @"诊断: 注册符号存在(未调用)" : @"诊断: 注册符号不存在");
        } else {
            HNPMAppendLog(@"MediaRemote 加载失败");
        }

        if (objc_getClass("CSActivityItemContentView"))      { %init(HNPMActivityCard); HNPMAppendLog(@"hook 已注册: 媒体卡片(高度>=150 过滤)"); }
        if (objc_getClass("_SAUIElementViewContentView"))    { %init(HNPMIslandElement); }
        if (objc_getClass("_SAUIProvidedViewContainerView")) { %init(HNPMIslandPortal); }
        if (objc_getClass("SBSystemApertureSceneElement"))   { %init(HNPMIslandSuppression); HNPMAppendLog(@"hook 已注册: 岛元素抑制策略+元素跟踪(NowPlaying)"); }
        HNPMAppendLog(@"v0.0.59: %ctor 正常完成");
    }
}
