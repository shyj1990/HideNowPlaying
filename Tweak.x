// HideNowPlaying v0.0.7 — 左滑触发修复版
//
// v0.0.5 真机日志结论(iPhone 15 Pro / iOS 17.0 / relaxin):
//   ✅ MRUNowPlayingViewController 就是锁屏播放卡片(viewDidLoad/viewWillAppear 正常触发)
//   ✅ hook 注册 / MediaRemote 播放速率检测全部正常
//   ❌ 挂在卡片 VC 根视图上的滑动手势收不到任何触摸(用户"滑不动") → 手势改挂到真实内容视图
//      MRUNowPlayingView 上, 并通过手势代理 shouldBeRequiredToFail 提升优先级
//   ❌ 灵动岛两个 VC 的 viewWillAppear 从未触发 → 改为直接跟踪 MRUAmbient*View 视图实例
//
// 功能(与 v0.0.5 相同):
//   1. 锁屏播放卡片左滑 → 隐藏卡片和灵动岛播放器(音乐不暂停)
//   2. 隐藏期间每 0.5s 检查播放速率: "暂停(≥1秒)→继续播放" → 自动恢复显示
//   3. 安全措施: 只 hook 真实存在的类 / 全部逻辑 @try 包裹 / 紧急开关 HideNowPlaying.off
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
    } @catch (NSException *exception) {
        // 任何情况下日志都不能让插件崩溃
    }
}

// 限流日志: 同类高频事件(如触摸回调)每秒最多记一条, 防止日志爆炸
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
static BOOL hnpmBaseline = NO;                // 是否完成隐藏后的第一次播放状态采样
static BOOL hnpmLastPlaying = NO;             // 上一次采样的播放状态
static int  hnpmPauseStreak = 0;              // 连续采样到"未在播放"的次数(防切歌瞬间误判)
static NSTimer *hnpmTimer = nil;              // 恢复检测定时器
static NSHashTable *hnpmCardViews = nil;      // 弱引用表: 锁屏卡片相关视图(MRUNowPlayingView / CellContentView)
static NSHashTable *hnpmAmbientViews = nil;   // 弱引用表: 灵动岛播放视图(MRUAmbient*View)
static void *kHNPMPanKey = &kHNPMPanKey;      // 关联对象 key: 标记已挂手势的视图

#pragma mark - MediaRemote(运行时 dlopen, 无需链接参数)

typedef void (*HNPMGetInfoFunc)(dispatch_queue_t, void (^)(CFDictionaryRef));
static HNPMGetInfoFunc hnpmGetInfo = NULL;

#pragma mark - 播放状态轮询(恢复检测)

static void HNPMCheckPlayback(void) {
    @try {
        if (!hnpmHidden || !hnpmGetInfo) { HNPMStopPolling(); return; }
        hnpmGetInfo(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(CFDictionaryRef info) {
            @try {
                if (!hnpmHidden) return;
                BOOL hasInfo = (info != NULL && CFDictionaryGetCount(info) > 0);
                BOOL playing = NO;
                if (hasInfo) {
                    CFNumberRef rateRef = CFDictionaryGetValue(info, CFSTR("kMRMediaRemoteNowPlayingInfoPlaybackRate"));
                    double rate = 0;
                    if (rateRef) CFNumberGetValue(rateRef, kCFNumberDoubleType, &rate);
                    playing = rate > 0.05;
                }
                if (!hnpmBaseline) {
                    // 隐藏后的第一次采样只记录基线, 不触发恢复
                    hnpmLastPlaying = playing;
                    hnpmPauseStreak = playing ? 0 : 1;
                    hnpmBaseline = YES;
                    return;
                }
                if (!playing) {
                    hnpmLastPlaying = NO;
                    hnpmPauseStreak++;
                    return;
                }
                // 从"连续≥2次未播放(≈1秒)"恢复到播放 → 判定为暂停后继续, 恢复显示
                if (!hnpmLastPlaying && hnpmPauseStreak >= 2) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        HNPMSetHidden(NO, @"检测到暂停后继续播放");
                    });
                }
                hnpmLastPlaying = YES;
                hnpmPauseStreak = 0;
            } @catch (NSException *e) {
                HNPMAppendLog([@"播放检测异常: " stringByAppendingString:e.description]);
            }
        });
    } @catch (NSException *e) {}
}

static void HNPMStartPolling(void) {
    if (hnpmTimer) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (hnpmTimer || !hnpmHidden) return;
        @try {
            NSTimer *t = [NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
                HNPMCheckPlayback();
            }];
            [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
            hnpmTimer = t;
            HNPMAppendLog(@"恢复检测定时器已启动(0.5s 轮询)");
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
        HNPMStartPolling();
    } else {
        HNPMStopPolling();
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            HNPMApplyHiddenToViews(hide);
            HNPMAppendLog([NSString stringWithFormat:@"%@ → 状态=%@ (卡片视图%lu个/灵动岛视图%lu个)",
                           reason, hide ? @"已隐藏(音乐继续)" : @"已恢复显示",
                           (unsigned long)hnpmCardViews.count, (unsigned long)hnpmAmbientViews.count]);
        } @catch (NSException *e) {}
    });
}

#pragma mark - 左滑手势 target + 代理(独立对象, 生命周期与进程相同)

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
            // 快速轻扫也认(位移不足但速度够快)
            if (t.x < -55 && fabs(t.x) > fabs(t.y) * 1.2 && v.x < -300) {
                HNPMSetHidden(YES, @"锁屏播放卡片左滑(轻扫)");
            }
        }
    } @catch (NSException *e) {}
}

// 只有"向左拖"的意图才让我们开始, 其它方向立即放弃, 把触摸还给系统
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

// 卡片内部的其它手势(按钮等)不受影响; 对卡片外层的手势(锁屏翻页等)我们优先
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

// 给视图挂左滑手势(每实例只挂一次)
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

static void *kHNPMDumpedKey = &kHNPMDumpedKey;   // 关联对象 key: 标记已 dump 过层级树的 VC

// 递归描述视图树(类名/尺寸/隐藏/透明度/是否可交互/挂了哪些手势)
static void HNPMDumpViewTree(UIView *view, NSMutableString *out, NSInteger depth, NSInteger *count) {
    @try {
        if (!view || *count > 80 || depth > 8) return;
        (*count)++;
        NSString *indent = depth > 0 ? [@"" stringByPaddingToLength:(NSUInteger)(depth * 2) withString:@" " startingAtIndex:0] : @"";
        [out appendFormat:@"%@%@ frame=%@ hidden=%d alpha=%.1f userInt=%d",
         indent, NSStringFromClass([view class]), NSStringFromCGRect(view.frame),
         view.hidden ? 1 : 0, view.alpha, view.userInteractionEnabled ? 1 : 0];
        NSArray *grs = [view gestureRecognizers];
        if (grs.count > 0) {
            NSMutableArray *names = [NSMutableArray array];
            for (UIGestureRecognizer *g in grs) [names addObject:NSStringFromClass([g class])];
            [out appendFormat:@" GR<%@>", [names componentsJoinedByString:@","]];
        }
        [out appendString:@"\n"];
        for (UIView *sub in [view subviews]) HNPMDumpViewTree(sub, out, depth + 1, count);
    } @catch (NSException *e) {}
}

#pragma mark - 类声明(供 logos 编译期使用)

@interface MRUNowPlayingViewController : UIViewController @end
@interface MRUAmbientNowPlayingViewController : UIViewController @end
@interface MRUAmbientCompactNowPlayingViewController : UIViewController @end
@interface SBLockScreenNowPlayingController : NSObject @end
@interface MRUNowPlayingView : UIView @end
@interface MRUNowPlayingCellContentView : UIView @end
@interface MRUNowPlayingContainerView : UIView @end
@interface MRUAmbientNowPlayingView : UIView @end
@interface MRUAmbientCompactNowPlayingView : UIView @end

#pragma mark - hooks

// ===== 锁屏卡片: 真实内容视图(手势挂载点) =====
%group HNPMCardView
%hook MRUNowPlayingView
- (void)didMoveToWindow {
    %orig;
    @try {
        [hnpmCardViews addObject:self];
        // 若内容视图本身不允许交互, 触摸根本进不来(v0.0.5 滑不动的头号嫌疑) → 打开它
        if (!self.userInteractionEnabled) {
            self.userInteractionEnabled = YES;
            HNPMAppendLog(@"[卡片] MRUNowPlayingView 原本 userInteractionEnabled=NO, 已改为 YES");
        }
        HNPMAttachPanIfNeeded(self);
        HNPMLogThrottled([NSString stringWithFormat:@"[卡片] MRUNowPlayingView 入层级 frame=%@ superview=%@",
                          NSStringFromCGRect(self.frame),
                          self.superview ? NSStringFromClass([self.superview class]) : @"(无)"]);
        if (hnpmHidden) self.hidden = YES;
    } @catch (NSException *e) {}
}
%end
%end

// ===== 锁屏卡片: 单元内容视图(备用隐藏目标 + 层级诊断) =====
%group HNPMCellView
%hook MRUNowPlayingCellContentView
- (void)didMoveToWindow {
    %orig;
    @try {
        [hnpmCardViews addObject:self];
        HNPMLogThrottled([NSString stringWithFormat:@"[卡片] MRUNowPlayingCellContentView 入层级 frame=%@",
                          NSStringFromCGRect(self.frame)]);
        if (hnpmHidden) self.hidden = YES;
    } @catch (NSException *e) {}
}
%end
%end

// ===== 锁屏卡片: 容器视图(仅诊断层级, 不做隐藏) =====
%group HNPMContainerView
%hook MRUNowPlayingContainerView
- (void)didMoveToWindow {
    %orig;
    @try {
        HNPMLogThrottled([NSString stringWithFormat:@"[卡片] MRUNowPlayingContainerView 入层级 frame=%@",
                          NSStringFromCGRect(self.frame)]);
    } @catch (NSException *e) {}
}
%end
%end

// ===== 锁屏卡片 VC: 隐藏期间保持隐藏(上一版已验证会触发) =====
%group HNPMCard
%hook MRUNowPlayingViewController
- (void)viewDidLoad {
    %orig;
    @try {
        HNPMAppendLog(@"[卡片] MRUNowPlayingViewController viewDidLoad");
    } @catch (NSException *e) {}
}
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    @try {
        HNPMLogThrottled([NSString stringWithFormat:@"[卡片] VC viewWillAppear view.frame=%@",
                          NSStringFromCGRect(self.view.frame)]);
        HNPMAttachPanIfNeeded(self.view);   // 兜底: 根视图也挂一份手势
        if (hnpmHidden) self.view.hidden = YES;
    } @catch (NSException *e) {}
}
- (void)viewDidLayoutSubviews {
    %orig;
    @try {
        if (hnpmHidden) self.view.hidden = YES;
        // 布局稳定后, 一次性 dump 卡片视图树 + 上级链(找出真正接收触摸的可见视图)
        if (self.view.frame.size.width > 50 && !objc_getAssociatedObject(self, kHNPMDumpedKey)) {
            objc_setAssociatedObject(self, kHNPMDumpedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            HNPMAttachPanIfNeeded(self.view);
            NSMutableString *chain = [NSMutableString stringWithString:@"[层级] 上级链: "];
            UIView *p = self.view;
            for (int i = 0; i < 5 && p; i++) {
                [chain appendFormat:@"%@%@(%@)", i ? @" <- " : @"", NSStringFromClass([p class]), NSStringFromCGRect(p.frame)];
                p = p.superview;
            }
            HNPMAppendLog(chain);
            NSMutableString *tree = [NSMutableString stringWithString:@"[层级] 卡片视图树:\n"];
            NSInteger count = 0;
            HNPMDumpViewTree(self.view, tree, 0, &count);
            HNPMAppendLog(tree);
        }
    } @catch (NSException *e) {}
}
%end
%end

// ===== 灵动岛: 直接跟踪视图实例(v0.0.5 里灵动岛 VC 从未触发, 改用视图层) =====
%group HNPMAmbientViewFull
%hook MRUAmbientNowPlayingView
- (void)didMoveToWindow {
    %orig;
    @try {
        [hnpmAmbientViews addObject:self];
        HNPMLogThrottled([NSString stringWithFormat:@"[灵动岛] MRUAmbientNowPlayingView 入层级 frame=%@",
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
        HNPMLogThrottled([NSString stringWithFormat:@"[灵动岛] MRUAmbientCompactNowPlayingView 入层级 frame=%@",
                          NSStringFromCGRect(self.frame)]);
        if (hnpmHidden) self.hidden = YES;
    } @catch (NSException *e) {}
}
%end
%end

// ===== 灵动岛 VC: 保留(万一某些场景会触发, 多一层保险) =====
%group HNPMAmbientFull
%hook MRUAmbientNowPlayingViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    @try { if (hnpmHidden) self.view.hidden = YES; } @catch (NSException *e) {}
}
- (void)viewDidLayoutSubviews {
    %orig;
    @try { if (hnpmHidden) self.view.hidden = YES; } @catch (NSException *e) {}
}
%end
%end

%group HNPMAmbientCompact
%hook MRUAmbientCompactNowPlayingViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    @try { if (hnpmHidden) self.view.hidden = YES; } @catch (NSException *e) {}
}
- (void)viewDidLayoutSubviews {
    %orig;
    @try { if (hnpmHidden) self.view.hidden = YES; } @catch (NSException *e) {}
}
%end
%end

// ===== 一次性诊断: SBLockScreenNowPlayingController 成员变量 =====
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
    HNPMAppendLog(@"v0.0.7: dylib 构造函数已执行(dyld 加载成功)");
}

%ctor {
    @autoreleasepool {
        HNPMAppendLog(@"v0.0.7: logos %ctor 进入");

        // 紧急开关
        if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/Documents/HideNowPlaying.off"]) {
            HNPMAppendLog(@"检测到开关文件 HideNowPlaying.off, 不注册任何 hook");
            return;
        }

        // 弱引用表(对象释放后自动从表里消失, 不会悬挂)
        hnpmCardViews = [NSHashTable weakObjectsHashTable];
        hnpmAmbientViews = [NSHashTable weakObjectsHashTable];

        // 手势 target
        hnpmPanTarget = [[HNPMPanTarget alloc] init];

        // MediaRemote 动态加载(用于"暂停→继续"恢复检测)
        void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
        if (mr) {
            hnpmGetInfo = (HNPMGetInfoFunc)dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
            HNPMAppendLog([NSString stringWithFormat:@"MediaRemote 已加载, 播放速率检测%@", hnpmGetInfo ? @"可用" : @"不可用"]);
        } else {
            HNPMAppendLog(@"MediaRemote 加载失败, 暂停恢复功能不可用");
        }

        // 按"类真实存在"才注册 hook
        if (objc_getClass("MRUNowPlayingView"))            { %init(HNPMCardView); HNPMAppendLog(@"hook 已注册: 卡片视图 MRUNowPlayingView(手势挂载点)"); }
        if (objc_getClass("MRUNowPlayingCellContentView")) { %init(HNPMCellView); HNPMAppendLog(@"hook 已注册: 卡片单元 MRUNowPlayingCellContentView"); }
        if (objc_getClass("MRUNowPlayingContainerView"))   { %init(HNPMContainerView); HNPMAppendLog(@"hook 已注册: 卡片容器 MRUNowPlayingContainerView(诊断)"); }
        if (objc_getClass("MRUNowPlayingViewController"))  { %init(HNPMCard); HNPMAppendLog(@"hook 已注册: 卡片 VC MRUNowPlayingViewController"); }
        if (objc_getClass("MRUAmbientNowPlayingView"))     { %init(HNPMAmbientViewFull); HNPMAppendLog(@"hook 已注册: 灵动岛视图 MRUAmbientNowPlayingView"); }
        if (objc_getClass("MRUAmbientCompactNowPlayingView")) { %init(HNPMAmbientViewCompact); HNPMAppendLog(@"hook 已注册: 灵动岛视图 MRUAmbientCompactNowPlayingView"); }
        if (objc_getClass("MRUAmbientNowPlayingViewController")) { %init(HNPMAmbientFull); }
        if (objc_getClass("MRUAmbientCompactNowPlayingViewController")) { %init(HNPMAmbientCompact); }
        if (objc_getClass("SBLockScreenNowPlayingController")) { %init(HNPMInspector); }

        HNPMAppendLog(@"v0.0.7: %ctor 正常完成");
    }
}
