// HideNowPlaying v0.0.23 — 岛内容隐藏(塌缩) + 播放信息重推送唤活
//
// v0.0.17 实测结论: 窗口级蒙版应用成功但仍裁不住媒体内容 → 蒙版路线放弃
//   (容器级蒙版 v0.0.16 失败, 窗口级蒙版 v0.0.17 也失败)
//
// v0.0.23 方案(回到实测有效路径 + 修黑壳):
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
static NSHashTable *hnpmIslandViews = nil;   // 弱引用: 灵动岛内容视图
static void *kHNPMPanKey = &kHNPMPanKey;

#pragma mark - MediaRemote

typedef void (*HNPMGetInfoFunc)(dispatch_queue_t, void (^)(CFDictionaryRef));
static HNPMGetInfoFunc hnpmGetInfo = NULL;
// void MRMediaRemoteSetNowPlayingInfo(CFDictionaryRef, dispatch_queue_t, id completion)
typedef void (*HNPMSetInfoFunc)(CFDictionaryRef, dispatch_queue_t, void (^)(void));
static HNPMSetInfoFunc hnpmSetInfo = NULL;
// void MRMediaRemoteSetNowPlayingApplicationIsPlaying(BOOL, dispatch_queue_t, void(^)(void))
// 系统级开关: 告诉系统"有没有 App 正在播放" → 让系统自己收起/重建媒体光圈(UIKit 动不了 CA 层光圈)
typedef void (*HNPMSetPlayingFunc)(BOOL, dispatch_queue_t, void (^)(void));
static HNPMSetPlayingFunc hnpmSetPlaying = NULL;

static void HNPMSetAppPlaying(BOOL playing, NSString *tag, BOOL quiet) {
    @try {
        if (!hnpmSetPlaying) return;
        dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
        if (!quiet) HNPMAppendLog([NSString stringWithFormat:@"[岛状态] %@ 调用 SetAppPlaying(%@)", tag, playing ? @"YES" : @"NO"]);
        hnpmSetPlaying(playing, q, ^{
            if (!quiet) HNPMAppendLog([NSString stringWithFormat:@"[岛状态] %@ 完成回调触发(%@)", tag, playing ? @"YES" : @"NO"]);
        });
    } @catch (NSException *e) {
        HNPMAppendLog(@"[岛状态] 调用异常");
    }
}

// "唤活": 取当前播放信息, 修改播放进度(+1s)后推回 —— 相同信息会被系统忽略,
// 只有变化的信息才能触发媒体实况重新渲染(治恢复黑壳)
static void HNPMReviveIslandContent(NSString *tag) {
    @try {
        if (!hnpmGetInfo || !hnpmSetInfo) return;
        HNPMLogThrottled([NSString stringWithFormat:@"[唤活] %@ 开始取播放信息", tag]);
        hnpmGetInfo(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(CFDictionaryRef info) {
            @try {
                if (hnpmHidden) return;
                if (!info || CFDictionaryGetCount(info) == 0) {
                    HNPMAppendLog(@"[唤活] 取到的播放信息为空, 跳过");
                    return;
                }
                CFMutableDictionaryRef dict = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, info);
                double newTime = 0;
                CFNumberRef tRef = (CFNumberRef)CFDictionaryGetValue(dict, CFSTR("kMRMediaRemoteNowPlayingInfoElapsedTime"));
                if (tRef) CFNumberGetValue(tRef, kCFNumberDoubleType, &newTime);
                newTime += 1.0;
                CFNumberRef newRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &newTime);
                CFDictionarySetValue(dict, CFSTR("kMRMediaRemoteNowPlayingInfoElapsedTime"), newRef);
                CFRelease(newRef);
                HNPMAppendLog(@"[唤活] 已构造变更信息, 推送中...");
                hnpmSetInfo((CFDictionaryRef)dict, dispatch_get_main_queue(), ^{
                    @try {
                        HNPMAppendLog(@"[唤活] 推送完成回调已触发");
                    } @catch (NSException *e) {}
                });
                CFRelease(dict);
            } @catch (NSException *e) {}
        });
    } @catch (NSException *e) {}
}

#pragma mark - 展开态侦察

// 顶部区域侦察: 只记录与 y<150 区域相交的视图(长胶囊在 y≈11~60)
static void HNPMReconWindowTopStrip(UIWindow *win, NSString *tag) {
    @try {
        if (!win) return;
        NSMutableString *out = [NSMutableString stringWithFormat:@"[侦察-顶部] %@ 窗口%@:\n", tag, NSStringFromClass([win class])];
        NSMutableArray *stack = [NSMutableArray arrayWithObject:win];
        NSMutableArray *depths = [NSMutableArray arrayWithObject:@0];
        int count = 0;
        while (stack.count > 0 && count < 300) {
            UIView *v = stack.firstObject;
            int depth = [depths.firstObject intValue];
            [stack removeObjectAtIndex:0];
            [depths removeObjectAtIndex:0];
            if (!v) continue;
            CGRect f = v.frame;
            BOOL inTop = (f.origin.y < 150);
            if (inTop) {
                count++;
                NSMutableString *line = [NSMutableString string];
                for (int i = 0; i < depth && i < 14; i++) [line appendString:@"  "];
                [line appendFormat:@"%@ f=%@", NSStringFromClass([v class]), NSStringFromCGRect(f)];
                if (v.isHidden) [line appendString:@" 隐藏"];
                if (v.alpha < 0.99) [line appendFormat:@" a=%.2f", v.alpha];
                [out appendFormat:@"%@\n", line];
            }
            NSArray *kids = [v subviews];
            for (UIView *k in kids) {
                [stack insertObject:k atIndex:0];
                [depths insertObject:@(depth + 1) atIndex:0];
            }
        }
        NSUInteger pos = 0;
        int seg = 1;
        while (pos < out.length) {
            NSUInteger len = MIN((NSUInteger)1400, out.length - pos);
            if (pos + len < out.length) {
                NSRange r = [out rangeOfString:@"\n" options:0 range:NSMakeRange(pos + len - 200, 200)];
                if (r.location != NSNotFound) len = r.location - pos + 1;
            }
            HNPMAppendLog([NSString stringWithFormat:@"%@ (段%d)", [out substringWithRange:NSMakeRange(pos, len)], seg++]);
            pos += len;
        }
    } @catch (NSException *e) {
        HNPMAppendLog(@"[侦察-顶部] 异常");
    }
}

#pragma mark - 媒体卡片判定

static BOOL HNPMIsMediaSized(CGSize size) {
    return size.width >= 300;
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

#pragma mark - 灵动岛隐藏 / 恢复

// 门户只处理媒体尺寸(>=30)的; 元素内容视图全部处理
static BOOL HNPMShouldTouchIslandView(UIView *v) {
    @try {
        NSString *n = NSStringFromClass([v class]);
        if ([n containsString:@"ProvidedViewContainer"] &&
            v.frame.size.width < 30 && v.frame.size.height < 30) return NO;
        return YES;
    } @catch (NSException *e) { return NO; }
}

static void HNPMHideIslandViews(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            for (UIView *v in hnpmIslandViews) {
                if (!v.window || !HNPMShouldTouchIslandView(v)) continue;
                [UIView animateWithDuration:0.25 animations:^{ v.alpha = 0.0; }
                                 completion:^(BOOL finished) {
                    @try {
                        if (hnpmHidden) v.hidden = YES;
                        v.alpha = 1.0;
                    } @catch (NSException *e) {}
                }];
            }
        } @catch (NSException *e) {}
    });
}

static void HNPMShowIslandViews(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            // ① 登记表里的视图
            for (UIView *v in hnpmIslandViews) {
                if (!v.window || !HNPMShouldTouchIslandView(v)) continue;
                if (!v.hidden) continue;
                v.hidden = NO;
            }
            // ② 全窗口类扫描兜底(覆盖恢复瞬间重建的实例)
            Class elementClass = objc_getClass("_SAUIElementViewContentView");
            Class portalClass = objc_getClass("_SAUIProvidedViewContainerView");
            if (elementClass || portalClass) {
                int healed = 0;
                for (UIWindow *w in [UIApplication sharedApplication].windows) {
                    NSMutableArray *stack = [NSMutableArray arrayWithObject:w];
                    while (stack.count > 0 && healed < 300) {
                        UIView *v = stack.firstObject;
                        [stack removeObjectAtIndex:0];
                        if (!v) continue;
                        Class c = [v class];
                        if ((elementClass && [c isKindOfClass:elementClass]) ||
                            (portalClass && [c isKindOfClass:portalClass])) {
                            if (v.hidden) { v.hidden = NO; healed++; }
                        }
                        [stack addObjectsFromArray:[v subviews]];
                    }
                }
                if (healed > 0) HNPMAppendLog([NSString stringWithFormat:@"[灵动岛] 扫描兜底恢复 %d 个视图", healed]);
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

static void HNPMShowCards(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            for (UIView *cell in hnpmCardCells) {
                if (!cell.window) continue;
                if (!HNPMCellHasLiveMedia(cell)) continue;
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

// 胶囊底板控制: 隐藏期间把 MagiciansCurtainView(岛的黑色胶囊背景)强制压回待机尺寸
// (v0.0.23 侦察: 内容隐藏后系统会重新展开胶囊 → 长黑条; 每次轮询再压回去)
static BOOL hnpmCurtainSavedExpanded = NO;
static CGRect hnpmCurtainExpandedFrame;

static void HNPMApplyCurtain(BOOL toHide, NSString *tag) {
    @try {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (![NSStringFromClass([w class]) containsString:@"Aperture"]) continue;
            NSMutableArray *stack = [NSMutableArray arrayWithObject:w];
            while (stack.count > 0) {
                UIView *v = stack.firstObject;
                [stack removeObjectAtIndex:0];
                if (!v) continue;
                NSString *cn = NSStringFromClass([v class]);
                if ([cn containsString:@"MagiciansCurtainView"]) {
                    CGRect f = v.frame;
                    if (toHide) {
                        if (f.size.width > 170) {
                            if (!hnpmCurtainSavedExpanded) {
                                hnpmCurtainSavedExpanded = YES;
                                hnpmCurtainExpandedFrame = f;
                            }
                            CGFloat W = w.frame.size.width;
                            CGRect compact = CGRectMake((W - 125.0) / 2.0, 11.333, 125.0, 36.667);
                            [UIView animateWithDuration:0.3 animations:^{ v.frame = compact; }];
                            HNPMAppendLog([NSString stringWithFormat:@"[岛底] %@ 压缩胶囊底板(%@, 原 %@)",
                                           tag, NSStringFromCGRect(compact), NSStringFromCGRect(f)]);
                        }
                    } else {
                        if (hnpmCurtainSavedExpanded && f.size.width < 170) {
                            CGRect ex = hnpmCurtainExpandedFrame;
                            [UIView animateWithDuration:0.3 animations:^{ v.frame = ex; }];
                            HNPMAppendLog([NSString stringWithFormat:@"[岛底] %@ 恢复底板(%@)", tag, NSStringFromCGRect(ex)]);
                        }
                    }
                }
                for (UIView *k in [v subviews]) [stack addObject:k];
            }
        }
    } @catch (NSException *e) {}
}

static void HNPMSetHidden(BOOL hide, NSString *reason) {
    if (hide == hnpmHidden) return;
    hnpmHidden = hide;
    hnpmBaseline = NO;
    hnpmPauseStreak = 0;
    if (hide) {
        HNPMHideCards();
        HNPMHideIslandViews();
        dispatch_async(dispatch_get_main_queue(), ^{ HNPMApplyCurtain(YES, @"隐藏"); });
        // 系统级开关: 告诉系统没有 App 在播放 → 让 CA 光圈自己收起(音频不受影响)
        HNPMSetAppPlaying(NO, @"隐藏", NO);
        // 最后一轮侦察: 锁屏窗口/通用窗口/根场景窗口的顶部区域 + 灵动岛窗口对照
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try {
                if (!hnpmHidden) return;
                for (UIWindow *w in [UIApplication sharedApplication].windows) {
                    NSString *n = NSStringFromClass([w class]);
                    if ([n containsString:@"Aperture"]) {
                        HNPMReconWindowTopStrip(w, @"Aperture");
                    } else if ([n containsString:@"CoverSheet"] || [n isEqualToString:@"SBWindow"] ||
                               [n containsString:@"RootScene"]) {
                        HNPMReconWindowTopStrip(w, @"候选");
                    }
                }
            } @catch (NSException *e) {}
        });
    } else {
        HNPMRestoreWithRetries();
        HNPMShowIslandViews();
        dispatch_async(dispatch_get_main_queue(), ^{ HNPMApplyCurtain(NO, @"恢复"); });
        // 光圈恢复: 设回"有 App 在播放" → 系统重建全新岛内容(治黑壳)
        NSArray *restoreDelays = @[@0.3, @1.0, @3.0];
        for (NSNumber *d in restoreDelays) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)([d doubleValue] * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                @try {
                    if (!hnpmHidden) HNPMSetAppPlaying(YES, [NSString stringWithFormat:@"恢复+%.1fs", [d doubleValue]], NO);
                } @catch (NSException *e) {}
            });
        }
        // 唤活: 视图已可见后重推播放信息, 逼远程内容重新渲染(治黑壳)
        NSArray *delays = @[@0.5, @1.5, @3.0];
        for (NSNumber *d in delays) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)([d doubleValue] * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                @try {
                    if (!hnpmHidden) HNPMReviveIslandContent([NSString stringWithFormat:@"恢复+%.1fs", [d doubleValue]]);
                } @catch (NSException *e) {}
            });
        }
    }
    HNPMAppendLog([NSString stringWithFormat:@"%@ → 状态=%@",
                   reason, hide ? @"已隐藏(音乐继续)" : @"已恢复显示"]);
}

// 0.5 秒轮询: 隐藏期间检测"暂停→继续播放"; 新出现的岛内容保持隐藏
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
                            for (UIView *v in hnpmIslandViews) {
                                if (v.window && HNPMShouldTouchIslandView(v) && !v.hidden) v.hidden = YES;
                            }
                            // 底板维持压缩: 系统重新展开就再压回去(记录打架)
                            HNPMApplyCurtain(YES, @"轮询");
                            // 光圈维持收起: App 重新上报播放状态就再压一次(静默)
                            HNPMSetAppPlaying(NO, @"轮询", YES);
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
                HNPMAttachPanIfNeeded(cell);
                HNPMLogThrottled([NSString stringWithFormat:@"[卡片] 媒体卡片登记 单元格=%@ 内容=%@",
                                  NSStringFromCGRect(cell.frame), NSStringFromCGRect(self.frame)]);
                if (hnpmHidden) {
                    self.hidden = YES;
                    cell.hidden = YES;
                } else if (cell.hidden || self.hidden) {
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
        HNPMLogThrottled([NSString stringWithFormat:@"[灵动岛] 门户登记 frame=%@",
                          NSStringFromCGRect(self.frame)]);
        if (hnpmHidden) self.hidden = YES;
    } @catch (NSException *e) {}
}
%end
%end

#pragma mark - 入口

__attribute__((constructor)) static void HNPMRawCtor(void) {
    HNPMAppendLog(@"v0.0.23: dylib 构造函数已执行(dyld 加载成功)");
}

%ctor {
    @autoreleasepool {
        HNPMAppendLog(@"v0.0.23: logos %ctor 进入");

        if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/Documents/HideNowPlaying.off"]) {
            HNPMAppendLog(@"检测到开关文件 HideNowPlaying.off, 不注册任何 hook");
            return;
        }

        hnpmCardCells = [NSHashTable weakObjectsHashTable];
        hnpmIslandViews = [NSHashTable weakObjectsHashTable];
        hnpmPanTarget = [[HNPMPanTarget alloc] init];

        void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
        if (mr) {
            hnpmGetInfo = (HNPMGetInfoFunc)dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
            hnpmSetInfo = (HNPMSetInfoFunc)dlsym(mr, "MRMediaRemoteSetNowPlayingInfo");
            hnpmSetPlaying = (HNPMSetPlayingFunc)dlsym(mr, "MRMediaRemoteSetNowPlayingApplicationIsPlaying");
            HNPMAppendLog([NSString stringWithFormat:@"MediaRemote 已加载, 播放检测%@ / 唤活%@ / 光圈开关%@",
                           hnpmGetInfo ? @"可用" : @"不可用",
                           hnpmSetInfo ? @"可用" : @"不可用",
                           hnpmSetPlaying ? @"可用" : @"不可用"]);
        } else {
            HNPMAppendLog(@"MediaRemote 加载失败");
        }

        if (objc_getClass("CSActivityItemContentView"))      { %init(HNPMActivityCard); HNPMAppendLog(@"hook 已注册: 媒体卡片(宽度过滤>=300)"); }
        if (objc_getClass("_SAUIElementViewContentView"))    { %init(HNPMIslandElement); }
        if (objc_getClass("_SAUIProvidedViewContainerView")) { %init(HNPMIslandPortal); }
        HNPMAppendLog(@"v0.0.23: %ctor 正常完成(岛内容隐藏+唤活)");
    }
}
