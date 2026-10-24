// HideNowPlaying v0.0.69 — 实时活动岛联动(模型级) + 身份探针 + 手势节流
//
// v0.0.69 三件套:
//   ①岛联动: 真机样本实锤实时活动上岛后 eid 形如 activity:<UUID>:<addr>。左滑实时活动卡 →
//     从锁屏单元格 ivar 树(对象型, 40个封顶, 2级父类)探 UUID/身份串 → 模型级抑制岛上含同身份的
//     activity: 元素(走 shouldSuppressElement* 苹果同款通道, 与 NativeIsland 共存安全;
//     探不到身份时兜底匹配全部 activity: 元素)。解除时机: 被抑制活动重新在场(登记身份匹配)/恢复锚
//     带同身份/兜底模式下任一类别2卡重新在场。+2s/+6s 重申防元素重建。
//   ②身份探针(HNPMProbeActivityUUIDs): 沿单元格 ivar 收集 UUID/activity: 形字符串, 命中上日志
//     ([身份] ivar=xxx 值=yyy), 为后续精确匹配积累样本。不缓存(单元格对象被系统复用)。
//   ③手势节流: 一次手势只触发一次隐藏/裁决(此前 Changed/Ended 多次过阈值, 一秒N次裁决+侦察)。
//   附带: HideCard 日志中性化(身份失灵期间音乐卡也曾被记成"实时活动")。
//
// v0.0.68 真机实锤(2026-10-21 日志): 所有卡(含音乐卡)全部登记为类别2、eid=(nil) —
//   CSActivityItemContentView 的内容是远程渲染的, 本地视图树没有 UILabel/UIButton/滑条,
//   特征评分只剩"高≥160"一项(两卡都167pt → 1分) → 全判类别2。
//   后果: ①手势只给类别1挂恢复链 → 音乐卡被判2 → 暂停恢复永远检测不到、ShowCards 身份闸门拒收;
//         ②岛联动同样丢失。
//   修正:
//   · 左滑裁决改走 MR 异步(HNPMSwipeSettle): 有活跃媒体会话 → 按音乐卡处理(hnpmHiddenCard=被滑卡,
//     挂监听+轮询); 无会话 → 纯实时活动卡。视图级隐藏不等裁决, 立即执行。
//   · 岛联动仅在"单卡"场景全开(多卡时无法排除滑的是实时活动; 且真机岛侦察只扫到锁图标,
//     媒体元素不走标准 Aperture 通道, 联动收益存疑)。
//   · ShowCards 摘掉身份闸门(按恢复锚恢复); 登记期"隐藏期重建保持隐藏"改认恢复锚。
//   · 登记日志加 按钮/滑条/时间标签/评分/锚 诊断项。
//   已知取舍: 音乐播放中左滑实时活动卡, 会被误入恢复通道(暂停恢复会把它带回来) — MR 无法区分
//   "滑的是哪张卡"; 待后续从单元格 ivar 里找到实时活动身份(bundle id)做精确匹配。
//
// v0.0.67 — 身份判定取代位置判定(三层): 模型标识沿链反查 → 内容特征评分 → 存疑退回位置启发式;
//   音乐卡与实时活动卡各自独立左滑隐藏; 下方卡被藏后上方可见卡自动下移补位(底边对齐,
//   0.6/2/5s 突发重申); 暂停恢复只救恢复锚; 实时活动卡被藏时触发岛侧侦察采样。
//
// v0.0.67 根因修复: 卡片判定原用"只认登记表里最底下那张"的位置启发式, 但外卖卡(带地图)高度
//   可达150~160pt, 同样通过登记(高≥150) → 登记表混入外卖卡 → ①音乐卡非最底→左滑被拒;
//   ②外卖卡最底→被当成正在播放卡误藏; ③暂停恢复把错藏的外卖卡放回。
//   → 身份判定取代位置判定(三层): ①模型标识沿链反查(复用岛侧已验证的 HNPMElementIdForView,
//   含 NowPlaying → 实锤) ②内容特征评分(±m:ss 双时间标签/≥3传输按钮/进度条/高≥160;
//   ≥4实锤/≤2拒/3存疑) ③存疑才退回旧位置启发式。
//
// v0.0.67 行为模型(按用户需求定稿):
//   · 音乐卡(类别1)与其他App实时活动卡(类别2)各自独立左滑隐藏, 互不影响;
//   · 下方卡被藏后, 上方在场卡自动下移补位(底边对齐被藏卡原底边; 系统列表不重排, 自己挪
//     transform; 0.6/2/5s 突发重申防系统布局pass重置);
//   · 暂停→恢复只救音乐卡(类别1), 左滑藏掉的实时活动卡绝不被暂停恢复通道放回;
//   · 只有音乐卡联动岛隐藏/模型级抑制/媒体监听链; 实时活动卡纯视图级, 岛不受影响;
//   · 每卡状态(类别/隐藏标志/下移位移)存关联对象, 登记/手势/重建/恢复统一读写;
//   · 恢复期登记(系统重建)对两种卡同规则: 藏过→保持隐藏, 没藏过→复原显示。
//
// v0.0.66 关键修正: 宽限期延迟终判(15秒) — v0.0.65 在 %ctor 一次性检测并永久缓存,
//   但 tweak 按文件名注入, HideNowPlaying 先于 NativeIsland 加载 → 检测必空(真机日志实锤)。
//   现在: 宽限期内每次调用重新检测, 15秒后冻结; 岛 hook 全部注册, 行为由调用层闸门动态拦截。
//
// v0.0.65 共存策略(分层退让):
//   碰岛的三条路径按冲突风险分层 — ①视图级直改(岛内容视图 hidden/重挂载/窗口抖动,
//   与 NativeIsland 类岛增强插件撞车高发区) ②模型级抑制(借用苹果自己的
//   shouldSuppressElement* 通道, 岛增强插件基本不会碰) ③通知列表媒体卡片(与岛无关, 永远保留)。
//   检测到 NativeIsland.dylib 已加载 → 停用①, 保留②③(岛隐藏功能仍在, 走最安全通道);
//   未检出 → 全功能(与 0.0.64 行为一致)。
//   手动覆盖: /var/mobile/Documents/HideNowPlaying.noisland     = 强制全停岛侧
//            /var/mobile/Documents/HideNowPlaying.forceisland  = 强制全功能(无视检测)
//   (原有 /var/mobile/Documents/HideNowPlaying.off 紧急全停开关不变)
//
// v0.0.63 实测全绿(2026-10-07): MR短暂注册+进程内监听复活, 隐藏→注册/恢复→注销完美成对,
//   隐藏期广播 5s 内 6~7 次(1s限流查询接住), 零卡死; 用户确认 CC 控制流畅、App 不卡。
//   彩蛋: 首次广播出现在注册之前 — SB 系统组件本就维持注册, 观察者搭系统顺风车。
//   0.0.54 冤案正式平反: 注册调用无罪(短暂注册已验证安全), GCD 定时器是唯一实锤凶手。
// v0.0.64: 稳态 1.5→2.0s — 播放状态变化已由通知驱动即时查询, 轮询降为兜底,
//   长隐藏期轮询次数再省 1/4; NSTimer+setFireDate 机制不动(0.0.57 终审安全路径)。
// 恢复速度预期: 暂停→播放若无通知兜底最慢 2s+ 状态机确认, 有通知则即时(通知驱动)。
//
// 日志: /var/mobile/Documents/HideNowPlaying.log   紧急开关: /var/mobile/Documents/HideNowPlaying.off

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <math.h>
#import <stdlib.h>
#import <string.h>

#pragma mark - 前置声明

static void HNPMSetHidden(BOOL hide, NSString *reason, BOOL linkIsland);
static BOOL HNPMPrefSwipeHide(void);   // v0.0.87: 前置声明(设置面板"锁屏左滑隐藏"总闸, 定义在后)
static void HNPMStartRestorePolling(void);
static void HNPMStartAlphaBurst(void);   // v0.0.90: 前置声明(亮屏逐帧连扫窗口, 定义在透明区)
static void HNPMScheduleDeepDumps(void);   // v0.0.95: 前置声明(时序化深诊断, 定义在屏幕状态CB之后)

#pragma mark - 日志

static void HNPMAppendLog(NSString *text) {
    @try {
        NSString *path = @"/var/mobile/Documents/HideNowPlaying.log";
        // v0.0.52: 日志上限 256KB, 超限清空重写(正式版只记关键事件, 不会再膨胀到 MB 级)
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
        if (attrs && [attrs fileSize] > 256 * 1024) [fm removeItemAtPath:path error:nil];
        // v0.0.90: 时间戳带毫秒(亮屏时序排障需要亚秒精度)
        static NSDateFormatter *fmt = nil;
        static dispatch_once_t onceTok;
        dispatch_once(&onceTok, ^{
            fmt = [[NSDateFormatter alloc] init];
            fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS Z";
            fmt.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        });
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [fmt stringFromDate:[NSDate date]], text];
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
static BOOL hnpmIslandLinked = NO;   // v0.0.68: 本次隐藏期是否允许碰岛(单卡/类别1 才开; 轮询与岛hook统一把门)
// v0.0.69: 实时活动岛联动(模型级) — 左滑实时活动卡 → 岛上 activity:<UUID>:<addr> 元素同步抑制
static BOOL hnpmActivitySuppress = NO;
static NSArray *hnpmActivityUUIDs = nil;      // 被滑卡探出的身份串(UUID或完整activity:串); 空=兜底匹配全部activity:元素
static NSHashTable *hnpmActivityTable = nil;  // 弱引用: 见过的 activity: 岛元素
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

// v0.0.55: 曾移除 0.0.54 的媒体通知注册 — 当时定罪注册调用搅乱媒体链路。
// v0.0.63 冤案复审: 0.0.56 证明 GCD 定时器单独即可致同款卡死, 注册调用从未单独测过;
// 且头文件实锤注册是媒体通知唯一正确通道(见文件头)。本版以"隐藏期短暂注册+恢复即注销"重启。

typedef void (*HNPMGetInfoFunc)(dispatch_queue_t, void (^)(CFDictionaryRef));
static HNPMGetInfoFunc hnpmGetInfo = NULL;

// v0.0.63: 媒体通知链路符号(头文件实锤的唯一正确通道, 见文件头注释)
typedef void (*HNPMRegFunc)(dispatch_queue_t);
typedef void (*HNPMUnregFunc)(void);
static HNPMRegFunc hnpmMRRegister = NULL;
static HNPMUnregFunc hnpmMRUnregister = NULL;
static NSString *hnpmInfoDidChangeName = nil;
static NSString *hnpmIsPlayingDidChangeName = nil;
static BOOL hnpmMRRegistered = NO;
static id hnpmMRObserver = nil;

// 隐藏→注册挂链 / 恢复→注销摘链(0.0.54 常驻注册的风险改造: 只在隐藏期短暂存在)
static void HNPMRegisterMediaListen(BOOL on) {
    @try {
        if (on) {
            if (hnpmMRRegistered) return;
            if (!hnpmMRRegister || !hnpmMRObserver) return;  // 符号缺失或观察者未挂上, 注册无意义
            hnpmMRRegister(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
            hnpmMRRegistered = YES;
            HNPMAppendLog(@"[监听MR] 已注册(隐藏期短暂挂链)");
        } else {
            if (!hnpmMRRegistered) return;
            if (hnpmMRUnregister) hnpmMRUnregister();
            hnpmMRRegistered = NO;
            HNPMAppendLog(@"[监听MR] 已注销(恢复摘链)");
        }
    } @catch (NSException *e) {
        HNPMAppendLog(@"[监听MR] 异常吞掉, 不影响主流程");
    }
}

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
                            // v0.0.87: 暂停→继续播放 无条件恢复(左滑功能开关只管手势, 不再接管恢复策略)
                            HNPMSetHidden(NO, @"检测到暂停后继续播放", YES);
                        }
                        hnpmLastPlaying = YES;
                        hnpmPauseStreak = 0;
                    }
                } @catch (NSException *e) {}
            });
        } @catch (NSException *e) {}
    });
}

// v0.0.60: 被动监听(双路纯收听, 零注册调用) — 隐藏期收到"媒体信息变化"广播 → 即时查询一次(限流1s防广播高频反噬省电)
static int hnpmNotifCount = 0;
static CFAbsoluteTime hnpmNotifLogAt = 0;
static CFAbsoluteTime hnpmNotifLastQuery = 0;
static BOOL hnpmNotifSeenA = NO;
static BOOL hnpmNotifSeenB = NO;
static BOOL hnpmNotifSeenMR = NO;

static void HNPMNotifyHit(NSString *path) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if ([path hasPrefix:@"A"] && !hnpmNotifSeenA) {
                hnpmNotifSeenA = YES;
                HNPMAppendLog(@"[通知] A路(CF Darwin中心)首次收到广播(验证通过)");
            } else if ([path hasPrefix:@"B"] && !hnpmNotifSeenB) {
                hnpmNotifSeenB = YES;
                HNPMAppendLog(@"[通知] B路(NS分布式)首次收到广播(验证通过)");
            } else if ([path hasPrefix:@"MR"] && !hnpmNotifSeenMR) {
                hnpmNotifSeenMR = YES;
                HNPMAppendLog(@"[通知] MR路(进程内)首次收到广播(验证通过)");
            }
            hnpmNotifCount++;
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (hnpmHidden) {
                if (now - hnpmNotifLogAt >= 5.0) {
                    HNPMAppendLog([NSString stringWithFormat:@"[通知] 隐藏期收到广播(5s内%d次)", hnpmNotifCount]);
                    hnpmNotifCount = 0;
                    hnpmNotifLogAt = now;
                }
                if (now - hnpmNotifLastQuery >= 1.0) {
                    hnpmNotifLastQuery = now;
                    HNPMQueryNowPlayingOnce();
                }
            }
        } @catch (NSException *e) {}
    });
}

// 嗅探器: name=nil 收所有分布式通知 — 回答两个问题: ①NS分布式在iOS17到底送不送货
// ②媒体广播有哪些名字(定向监听静默可能是名字不对)。[嗅探]行上限30/会话防刷屏。
static NSMutableSet *hnpmSniffSeen = nil;
static int hnpmSniffLines = 0;

static void HNPMNotifySniff(NSNotification *note) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (hnpmSniffLines >= 30 || !note.name) return;
            NSString *name = note.name;
            BOOL media = ([name rangeOfString:@"ediaRemote"].location != NSNotFound
                          || [name rangeOfString:@"owPlaying"].location != NSNotFound);
            if (!hnpmSniffSeen) hnpmSniffSeen = [NSMutableSet set];
            if (![hnpmSniffSeen containsObject:name]) {
                [hnpmSniffSeen addObject:name];
                hnpmSniffLines++;
                HNPMAppendLog([NSString stringWithFormat:@"[嗅探] %@", name]);
            } else if (media) {
                hnpmSniffLines++;
                HNPMAppendLog([NSString stringWithFormat:@"[嗅探] %@(再次)", name]);
            }
            if (media) HNPMNotifyHit(@"B(嗅探)");
        } @catch (NSException *e) {}
    });
}

// B路: NSDistributedNotificationCenter(Foundation 全链接, 内部自己解析 CF 符号, 绕开 dlsym 死路)
// v0.0.60 实锤: 运行时存在、挂载成功, 但定向监听全程静默 → v0.0.61 加全量嗅探分辨"不送货"还是"名字不对"
static void HNPMPassiveListenB(void) {
    @try {
        Class dncClass = objc_getClass("NSDistributedNotificationCenter");
        if (!dncClass) { HNPMAppendLog(@"监听B(NS分布式): 运行时无此类, 未挂起"); return; }
        id dnc = [(id)dncClass performSelector:@selector(defaultCenter)];
        if (!dnc) { HNPMAppendLog(@"监听B(NS分布式): defaultCenter 为空, 未挂起"); return; }
        typedef id (*AddObsMsgSend)(id, SEL, id, id, id, id);
        SEL addSel = NSSelectorFromString(@"addObserverForName:object:queue:usingBlock:");
        ((AddObsMsgSend)objc_msgSend)(dnc, addSel,
            @"com.apple.mediaremote.nowplaying.info-did-change", (id)nil, (id)nil,
            ^(NSNotification *note) { HNPMNotifyHit(@"B(定向)"); });
        ((AddObsMsgSend)objc_msgSend)(dnc, addSel, (id)nil, (id)nil, (id)nil,
            ^(NSNotification *note) { HNPMNotifySniff(note); });
        HNPMAppendLog(@"监听B已挂×2: 定向(info-did-change) + 全量嗅探(纯收听)");
    } @catch (NSException *e) {
        HNPMAppendLog(@"监听B(NS分布式): 挂载异常, 未挂起");
    }
}

// A路: CF Darwin 中心(纯收听) — v0.0.60"死路"真相=函数名拼错: iOS 真名无s, 之前查的是 macOS 名(带s)。
// dlsym 正名优先+旧名兜底(拿不到只降级不崩, 不走链接期符号避开 dyld 硬崩); 挂两个候选广播名。
static void HNPMDarwinCallback(CFNotificationCenterRef center, void *observer,
                               CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    static BOOL loggedName = NO;
    if (!loggedName) {
        loggedName = YES;
        NSString *n = name ? (__bridge NSString *)name : @"(空)";
        HNPMAppendLog([NSString stringWithFormat:@"[通知] A路回调首次触发 name=%@", n]);
    }
    HNPMNotifyHit(@"A(定向)");
}

static void HNPMPassiveListenA(void) {
    @try {
        typedef void *(*GetCenterFunc)(void);
        GetCenterFunc getCenter = (GetCenterFunc)dlsym(RTLD_DEFAULT, "CFNotificationCenterGetDarwinNotifyCenter");
        const char *via = "NotifyCenter(iOS真名,无s)";
        if (!getCenter) {
            getCenter = (GetCenterFunc)dlsym(RTLD_DEFAULT, "CFNotificationCenterGetDarwinNotificationCenter");
            via = "NotificationCenter(macOS旧名,带s)";
        }
        if (!getCenter) { HNPMAppendLog(@"监听A: 两名均dlsym不到, 未挂起"); return; }
        CFNotificationCenterRef dc = (CFNotificationCenterRef)getCenter();
        if (!dc) { HNPMAppendLog([NSString stringWithFormat:@"监听A: 中心空(%s), 未挂起", via]); return; }
        CFNotificationCenterAddObserver(dc, NULL, HNPMDarwinCallback,
            CFSTR("com.apple.mediaremote.nowplaying.info-did-change"),
            NULL, CFNotificationSuspensionBehaviorCoalesce);
        CFNotificationCenterAddObserver(dc, NULL, HNPMDarwinCallback,
            CFSTR("com.apple.mediaremote.nowplayinginfochanged"),
            NULL, CFNotificationSuspensionBehaviorCoalesce);
        HNPMAppendLog([NSString stringWithFormat:@"监听A已挂(%s)×2候选名", via]);
    } @catch (NSException *e) {
        HNPMAppendLog(@"监听A: 挂载异常, 未挂起");
    }
}

#pragma mark - 岛侧共存 (v0.0.66)

// v0.0.66 关键修正: v0.0.65 在 %ctor 里一次性检测并永久缓存, 但 tweak 按文件名注入,
//   HideNowPlaying.dylib < NativeIsland.dylib → HNP 构造函数先执行时 NativeIsland 尚未加载
//   → 检测必空且缓存被污染(真机日志实锤: [共存] 岛侧模式: 全功能 (NativeIsland 未检出))。
//   修正: 启动后 15 秒为宽限期 — 期间每次调用都重新检测(此时全部 tweak 必已加载),
//   15 秒后冻结缓存。检测命中即永久记住(镜像表/类表只增不减)。
static double hnpmLaunchTime = 0;                 // %ctor 里设置(参考时间基准)
static double hnpmLastClassScan = 0;              // 类名兜底扫描限流
static volatile int hnpmNativeIslandState = -1;   // -1未冻结 0无 1有

static BOOL HNPMGracePeriodActive(void) {
    return hnpmLaunchTime > 0
        && ([NSDate timeIntervalSinceReferenceDate] - hnpmLaunchTime) < 15.0;
}

static BOOL HNPMNativeIslandPresent(void) {
    BOOL frozen = !HNPMGracePeriodActive();
    if (frozen && hnpmNativeIslandState >= 0) return hnpmNativeIslandState == 1;
    BOOL found = NO;
    @try {
        // 1) 镜像表扫描 — 代价极低, 宽限期内每次调用都执行
        uint32_t n = _dyld_image_count();
        for (uint32_t i = 0; i < n; i++) {
            const char *p = _dyld_get_image_name(i);
            if (!p) continue;
            NSString *path = [[NSString alloc] initWithUTF8String:p];
            if ([path rangeOfString:@"NativeIsland" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                found = YES;
                break;
            }
        }
        // 2) 兜底: 若 roothide patcher 重命名了 dylib(镜像路径扫不到), 改查其 Swift 类前缀。
        //    NativeIsland 1.0.3 实测为 Swift+Orion 插件, 类名硬编码为 _TtC12NativeIsland*(改不掉)。
        //    objc_copyClassList 开销较大 — 限流至多每 5 秒一次, 检出后不再扫。
        double now = [NSDate timeIntervalSinceReferenceDate];
        if (!found && (now - hnpmLastClassScan) >= 5.0) {
            hnpmLastClassScan = now;
            unsigned int cnt = 0;
            Class *classes = objc_copyClassList(&cnt);
            if (classes) {
                for (unsigned int i = 0; i < cnt; i++) {
                    const char *nm = class_getName(classes[i]);
                    if (nm && strncmp(nm, "_TtC12NativeIsland", 18) == 0) { found = YES; break; }
                }
                free(classes);
            }
        }
    } @catch (NSException *e) {}
    if (found) {
        hnpmNativeIslandState = 1;   // 检出即永久记住
    } else if (frozen) {
        hnpmNativeIslandState = 0;   // 宽限期结束仍未检出 → 判定为无
    }
    return found;
}

// 岛侧模式(宽限期内动态评估, 15 秒后冻结):
//   0 = 全停岛侧(noisland 开关文件)
//   1 = 仅模型级抑制(检测到 NativeIsland — 视图级直改停用, 避开撞车高发区)
//   2 = 全功能(未检出 NativeIsland, 或 forceisland 强制)
static volatile int hnpmIslandMode = -1;

static int HNPMIslandMode(void) {
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        if ([fm fileExistsAtPath:@"/var/mobile/Documents/HideNowPlaying.noisland"]) {
            hnpmIslandMode = 0;
            return 0;
        }
        if ([fm fileExistsAtPath:@"/var/mobile/Documents/HideNowPlaying.forceisland"]) {
            hnpmIslandMode = 2;
            return 2;
        }
    } @catch (NSException *e) {}
    int m = HNPMNativeIslandPresent() ? 1 : 2;
    if (!HNPMGracePeriodActive()) hnpmIslandMode = m;   // 仅冻结后落缓存
    return m;
}

static NSString *HNPMIslandModeName(int mode) {
    switch (mode) {
        case 0:  return @"全停(noisland)";
        case 1:  return @"仅模型级抑制(检出NativeIsland)";
        default: return @"全功能";
    }
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

// v0.1.10: 卡体探测 — 单元格内含宽>=300 高>=minH 的媒体内容视图(音乐卡/实时活动通用)。
//          v0.1.9 日志实测: 正在播放内容视图可能只有 365x143(旧侦察 167, 150 分界线误杀)
static UIView *HNPMCellMediaContent(UIView *cell, CGFloat minH) {
    @try {
        Class contentClass = objc_getClass("CSActivityItemContentView");
        if (!contentClass || !cell) return nil;
        NSMutableArray *stack = [NSMutableArray arrayWithObject:cell];
        int guard = 0;
        while (stack.count > 0 && guard++ < 200) {
            UIView *v = stack.firstObject;
            [stack removeObjectAtIndex:0];
            if (!v) continue;
            if ([v isKindOfClass:contentClass] &&
                v.frame.size.width >= 300 && v.frame.size.height >= minH) return v;
            [stack addObjectsFromArray:[v subviews]];
        }
    } @catch (NSException *e) {}
    return nil;
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

#pragma mark - 锁屏卡片身份判定 (v0.0.67)

// v0.0.67: "只认最底下那张"的位置启发式在"其他App实时活动位于音乐卡下方"时全部失效
// (外卖卡带地图高可达150~160pt 同样通过登记 → 登记表混入 → 音乐卡永被拒/滑错卡/恢复错卡)。
// 修复: 身份判定取代位置判定 —
//   ①模型标识沿链反查(复用岛侧已验证的 HNPMElementIdForView): 含 NowPlaying → 实锤;
//     实锤其他归属 → 拒。
//   ②内容特征评分: 正在播放卡独有 ±m:ss 双时间标签(+2) / ≥3传输按钮(+2) / 进度条(+1) /
//     高≥160(+1) → ≥4 实锤, ≤2 实锤其他活动, 3 存疑。
//   ③存疑才退回"最底下"旧启发式(HNPMIsBottomMostMediaCell, 保底兼容旧行为)。

static void *kHNPMCellClassKey = &kHNPMCellClassKey;   // 关联对象: 单元格类别缓存

// 单元格类别: 1=正在播放卡 2=其他App实时活动 0=无媒体内容 -1=未分类/存疑
static int HNPMCellClassGet(UIView *cell) {
    NSNumber *n = objc_getAssociatedObject(cell, kHNPMCellClassKey);
    return n ? [n intValue] : -1;
}
static void HNPMCellClassSet(UIView *cell, int k) {
    objc_setAssociatedObject(cell, kHNPMCellClassKey, @(k), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// 时间标签识别: ±m:ss / mm:ss / h:mm:ss(正在播放卡必有 已播+剩余(-) 两个;
// "预计12:16送达"这类带中文的永远不会误判)
static BOOL HNPMIsTimeLabelText(NSString *txt) {
    if (txt.length < 3 || txt.length > 8) return NO;
    NSInteger colons = 0, digits = 0;
    for (NSUInteger i = 0; i < txt.length; i++) {
        unichar c = [txt characterAtIndex:i];
        if (c == ':') { if (digits < 1 || digits > 2) return NO; colons++; digits = 0; }
        else if (c == '-') { if (i != 0) return NO; }
        else if (c >= '0' && c <= '9') digits++;
        else return NO;
    }
    return (colons == 1 || colons == 2) && digits >= 1 && digits <= 2;
}

typedef struct { int buttons; int sliders; int timeLabels; } HNPMCellTraits;

static HNPMCellTraits HNPMScanCellTraits(UIView *cell) {
    HNPMCellTraits t = {0, 0, 0};
    @try {
        NSMutableArray *stack = [NSMutableArray arrayWithObject:cell];
        int guard = 0;
        while (stack.count > 0 && guard++ < 300) {
            UIView *v = stack.firstObject;
            [stack removeObjectAtIndex:0];
            if (!v) continue;
            [stack addObjectsFromArray:v.subviews];
            NSString *cls = NSStringFromClass([v class]);
            CGSize sz = v.bounds.size;
            if ([v isKindOfClass:[UISlider class]]
                || [cls containsString:@"Slider"] || [cls containsString:@"ProgressView"]) {
                if (t.sliders < 9) t.sliders++;
            }
            if ([cls containsString:@"Button"]
                && sz.width >= 24.0 && sz.width <= 90.0 && sz.height >= 24.0 && sz.height <= 90.0) {
                if (t.buttons < 9) t.buttons++;
            }
            if ([v isKindOfClass:[UILabel class]] && HNPMIsTimeLabelText([(UILabel *)v text])) {
                if (t.timeLabels < 9) t.timeLabels++;
            }
        }
    } @catch (NSException *e) {}
    return t;
}

// 特征评分: ≥4 实锤正在播放; ≤2 实锤其他活动; 3 存疑
static int HNPMTraitsScore(HNPMCellTraits t, CGFloat cellH) {
    int s = 0;
    if (t.timeLabels >= 2) s += 2; else if (t.timeLabels == 1) s += 1;
    if (t.buttons >= 3) s += 2; else if (t.buttons == 2) s += 1;
    if (t.sliders >= 1) s += 1;
    if (cellH >= 160.0) s += 1;   // 音乐卡≈167+, 外卖卡约150~160(按0~1计, 不做硬分界)
    return s;
}

// 身份判定主入口: 返回 1/2/-1(存疑)/0(无媒体内容); eidOut 带回模型标识(可nil, 诊断用)
static int HNPMClassifyListCell(UIView *cell, NSString **eidOut) {
    if (eidOut) *eidOut = nil;
    if (!cell || !HNPMCellHasLiveMedia(cell)) return 0;
    // ① 模型标识: 沿链反查(向上6层+每层3级父类ivar, 与岛侧同款)
    NSString *eid = HNPMElementIdForView(cell);
    if (eidOut) *eidOut = eid;
    if (eid && [eid containsString:@"NowPlaying"]) return 1;
    if (eid) return 2;
    // ② 内容特征
    HNPMCellTraits t = HNPMScanCellTraits(cell);
    int score = HNPMTraitsScore(t, cell.bounds.size.height);
    if (score >= 4) return 1;
    if (score <= 2) return 2;
    return -1;   // ③ 存疑 → 调用方决定(退回位置启发式)
}

// v0.0.68: HNPMIsNowPlayingCell 已删除 — 真机实锤远程渲染导致本地分类全军覆没(全判类别2),
// 该判定无调用价值; 音乐/实时活动通道改由 HNPMSwipeSettle 的 MR 会话裁决 + 恢复锚机制承担。

// ---- 每卡独立状态: 左滑隐藏标志 / 已应用的下移位移 ----
static void *kHNPMCardHiddenKey = &kHNPMCardHiddenKey;
static BOOL HNPMCardHiddenGet(UIView *cell) {
    NSNumber *n = objc_getAssociatedObject(cell, kHNPMCardHiddenKey);
    return n ? [n boolValue] : NO;
}
static void HNPMCardHiddenSet(UIView *cell, BOOL h) {
    objc_setAssociatedObject(cell, kHNPMCardHiddenKey, @(h), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static void *kHNPMCardShiftKey = &kHNPMCardShiftKey;
static CGFloat HNPMCardShiftGet(UIView *cell) {
    NSNumber *n = objc_getAssociatedObject(cell, kHNPMCardShiftKey);
    return n ? [n doubleValue] : 0.0;
}
static void HNPMCardShiftSet(UIView *cell, CGFloat s) {
    objc_setAssociatedObject(cell, kHNPMCardShiftKey, @(s), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
// v0.0.74: 托盘透明化重试计数(托盘由 _configurePlatterViewIfNecessary 惰性创建, 可能晚于首次登记)
static void *kHNPMAlphaRetryKey = &kHNPMAlphaRetryKey;
static NSInteger HNPMAlphaRetryGet(UIView *cell) {
    NSNumber *n = objc_getAssociatedObject(cell, kHNPMAlphaRetryKey);
    return n ? [n integerValue] : 0;
}
static void HNPMAlphaRetrySet(UIView *cell, NSInteger c) {
    objc_setAssociatedObject(cell, kHNPMAlphaRetryKey, @(c), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// 原始底边Y(窗口坐标, 扣除我们自己做过的下移位移, 拿到未平移的基准位置)
static CGFloat HNPMCardRawBottom(UIView *cell) {
    CGRect wr = [cell convertRect:cell.bounds toView:nil];
    return wr.origin.y + wr.size.height - HNPMCardShiftGet(cell);
}

// v0.0.67: 下方卡片被左滑藏掉后系统列表不重排, 上方在场卡片要自己下移补位
// (可见卡底边对齐到下方被藏卡的原底边; 自底向上扫一遍, 一张/两张/全藏都安全)
static void HNPMApplyCardLayout(BOOL animated) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ HNPMApplyCardLayout(animated); });
        return;
    }
    @try {
        NSMutableArray *cards = [NSMutableArray array];
        for (UIView *c in hnpmCardCells) if (c.window) [cards addObject:c];
        if (cards.count == 0) return;
        [cards sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
            CGFloat ya = HNPMCardRawBottom(a), yb = HNPMCardRawBottom(b);
            return ya < yb ? NSOrderedAscending : (ya > yb ? NSOrderedDescending : NSOrderedSame);
        }];
        CGFloat targetBottom = -CGFLOAT_MAX;   // 下方被藏卡的原底边(可见卡的对齐目标)
        BOOL haveTarget = NO;
        for (UIView *c in cards) {   // 自底向上
            if (HNPMCardHiddenGet(c)) {
                CGFloat b = HNPMCardRawBottom(c);
                if (b > targetBottom) targetBottom = b;
                haveTarget = YES;
                continue;
            }
            if (!haveTarget) continue;
            CGFloat dy = targetBottom - HNPMCardRawBottom(c);
            haveTarget = NO;
            if (dy < 0.5 || dy > 500.0) continue;   // 只下移; 异常值不挪
            HNPMCardShiftSet(c, dy);
            void (^apply)(void) = ^{
                c.transform = CGAffineTransformTranslate(CGAffineTransformIdentity, 0, dy);
            };
            if (animated) {
                [UIView animateWithDuration:0.35
                                      delay:0.0
                                    options:UIViewAnimationOptionCurveEaseIn
                                 animations:apply
                                 completion:nil];
            } else {
                apply();
            }
            HNPMAppendLog([NSString stringWithFormat:@"[补位] 可见卡下移 %.0f", dy]);
        }
    } @catch (NSException *e) {}
}

// 补位后小突发重申(防系统布局pass重置transform): 0.6/2/5s 各试一次, 无差异则空转
static void HNPMLayoutRetryBurst(void) {
    NSArray *delays = @[@0.6, @2.0, @5.0];
    for (NSNumber *d in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)([d doubleValue] * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ HNPMApplyCardLayout(YES); });
    }
}

// ---- v0.0.71: 卡片背景透明度 ----
// v0.0.87: 配置优先级 = 设置面板(CFPreferences bgAlpha) > 文件(/var/mobile/Documents/HideNowPlaying.alpha)
//          > 默认 0.55; 1.0 = 关闭功能; 5s 缓存防频繁读盘, 面板改动经 darwin 通知即时清缓存。
static CGFloat hnpmBgAlphaCached = -1.0;
static CFAbsoluteTime hnpmBgAlphaCachedAt = 0;
static void HNPMBgAlphaInvalidate(void) { hnpmBgAlphaCached = -1.0; }

// v0.0.87: 设置面板"锁屏左滑隐藏"功能总闸(CFPreferences; 无配置默认开)
//   开 = 锁屏左滑可隐藏音乐卡/实时活动卡并联动岛, 暂停→继续播放自动恢复;
//   关 = 左滑手势不生效(已隐藏的立即恢复)。
static BOOL HNPMPrefSwipeHide(void) {
    Boolean ok = NO;
    BOOL v = CFPreferencesGetAppBooleanValue(CFSTR("swipeHide"), CFSTR("com.aha.hidenowplaying"), &ok);
    return ok ? (BOOL)v : YES;
}

static CGFloat HNPMBgAlpha(void) {
    if (hnpmBgAlphaCached >= 0 && CFAbsoluteTimeGetCurrent() - hnpmBgAlphaCachedAt < 5.0) return hnpmBgAlphaCached;
    CGFloat v = 0.55;
    CFTypeRef pv = CFPreferencesCopyAppValue(CFSTR("bgAlpha"), CFSTR("com.aha.hidenowplaying"));
    if (pv) {
        v = (CGFloat)[(__bridge NSNumber *)pv doubleValue];
        CFRelease(pv);
    } else {
        NSString *s = [NSString stringWithContentsOfFile:@"/var/mobile/Documents/HideNowPlaying.alpha"
                                                encoding:NSUTF8StringEncoding error:nil];
        if (s) v = s.doubleValue;
    }
    if (v < 0.05) v = 0.05;
    if (v > 1.0) v = 1.0;
    hnpmBgAlphaCached = v;
    hnpmBgAlphaCachedAt = CFAbsoluteTimeGetCurrent();
    return v;
}

// v0.0.99: 前置声明(诊断 dump/登记路径直接调 materialRecipe/isBackgroundBlurred,
//          原声明在文件尾部 %hook 前, 编译顺序不够) — 空接口不够, 须声明用到的属性
//          (真机类由 PLPlatterKit 提供, 此处仅让编译器放行, 运行时按真实现解析)
@interface PLPlatterView : UIView
@property (nonatomic) long long materialRecipe;
@property (getter=isBackgroundBlurred, nonatomic) BOOL backgroundBlurred;
@end

// v0.0.99: 官方材质配方实验 — /var/mobile/Documents/HideNowPlaying.recipe 写入整数(如 2/3/0)
//          → 登记路径对托盘 setMaterialRecipe:, 让系统自己渲该配方(候选免 alpha 写入路线)。
//          删文件或写 -1 = 不覆盖。5s 缓存。
static NSInteger hnpmRecipeCached = -2;   // -2 = 未读
static CFAbsoluteTime hnpmRecipeCachedAt = 0;
static NSInteger HNPMRecipeOverride(void) {
    if (hnpmRecipeCached != -2 && CFAbsoluteTimeGetCurrent() - hnpmRecipeCachedAt < 5.0)
        return hnpmRecipeCached;
    NSString *s = [NSString stringWithContentsOfFile:@"/var/mobile/Documents/HideNowPlaying.recipe"
                                            encoding:NSUTF8StringEncoding error:nil];
    hnpmRecipeCached = s ? (NSInteger)s.integerValue : -1;
    hnpmRecipeCachedAt = CFAbsoluteTimeGetCurrent();
    return hnpmRecipeCached;
}

// v0.0.75: 托盘内部结构一次性诊断 — 确认 backgroundView(白底)/customContentView(内容)分层,
//          供排障; 每次解锁进程只 dump 一次。
static BOOL sHNPMPlatterDiagDumped = NO;
static void HNPMPlatterDiagDump(UIView *platter, UIView *bg, NSString *via) {
    if (sHNPMPlatterDiagDumped) return;
    sHNPMPlatterDiagDumped = YES;
    @try {
        NSMutableArray *rows = [NSMutableArray array];
        NSString *recipeStr = @"";
        @try {
            if ([platter respondsToSelector:@selector(materialRecipe)])
                recipeStr = [NSString stringWithFormat:@" recipe=%lld", [(PLPlatterView *)platter materialRecipe]];
        } @catch (NSException *e) {}
        [rows addObject:[NSString stringWithFormat:@"托盘%@ f=%@ via=%@(%@)%@", NSStringFromClass([platter class]), NSStringFromCGRect(platter.frame), via, NSStringFromCGRect(bg.frame), recipeStr]];
        for (UIView *s in platter.subviews) {
            [rows addObject:[NSString stringWithFormat:@"%@ f=%@ a=%.2f h=%d", NSStringFromClass([s class]), NSStringFromCGRect(s.frame), s.alpha, s.isHidden ? 1 : 0]];
        }
        HNPMAppendLog([NSString stringWithFormat:@"[透明·诊断] %@", [rows componentsJoinedByString:@" || "]]);
        // v0.0.98/99: 官方旋钮探测 — materialRecipe(配方号)/isBackgroundBlurred/
        //          recipeNamesByTraitCollection(配方名映射, 供猜可用配方)
        @try {
            if ([platter respondsToSelector:@selector(materialRecipe)]) {
                HNPMAppendLog([NSString stringWithFormat:@"[透明·诊断] materialRecipe=%lld",
                               [(PLPlatterView *)platter materialRecipe]]);
            } else {
                HNPMAppendLog(@"[透明·诊断] materialRecipe 选择器不存在");
            }
            // v0.0.99: 修正 v0.0.98 探测笔误 — backgroundBlurred 的 getter 是 isBackgroundBlurred
            if ([platter respondsToSelector:@selector(isBackgroundBlurred)]) {
                HNPMAppendLog([NSString stringWithFormat:@"[透明·诊断] backgroundBlurred=%d",
                               [(PLPlatterView *)platter isBackgroundBlurred] ? 1 : 0]);
            } else {
                HNPMAppendLog(@"[透明·诊断] isBackgroundBlurred 选择器不存在");
            }
            id names = nil;
            @try { names = [platter valueForKey:@"recipeNamesByTraitCollection"]; } @catch (NSException *e) {}
            if (names) HNPMAppendLog([NSString stringWithFormat:@"[透明·诊断] 配方名映射=%@",
                                      [names description]]);
        } @catch (NSException *e) {
            HNPMAppendLog(@"[透明·诊断] 旋钮探测异常");
        }
    } @catch (NSException *e) {}
}

// v0.0.88: 取托盘的背景子层(KVC backgroundView → backgroundMaterialView), 登记路径与亮屏重申共用
static UIView *HNPMPlatterBgView(UIView *platter, NSString **viaOut) {
    NSString *via = @"";
    UIView *bg = nil;
    @try {
        id x = [platter valueForKey:@"backgroundView"];
        if ([x isKindOfClass:[UIView class]]) { bg = x; via = @"backgroundView"; }
    } @catch (NSException *e) {}
    if (!bg) {
        @try {
            id x = [platter valueForKey:@"backgroundMaterialView"];
            if ([x isKindOfClass:[UIView class]]) { bg = x; via = @"backgroundMaterialView"; }
        } @catch (NSException *e) {}
    }
    if (viaOut) *viaOut = via;
    return bg;
}

// v0.0.88: 对单个托盘重申目标 alpha(bg 子层优先, 无 bg 退回整托盘)。
// 返回实际发生的改动数(0 = 已是目标值, 零成本空转)。
// v0.0.95: alpha 写入统一禁用隐式动画(CATransaction) — off 对照 + 0.7 滑条实验表明:
//          歌词变暗与 alpha 数值无关(0.25/0.7 都暗、原生 1.0 不暗) → 诱因是"写入"本身:
//          对材质的带动画属性写入可能促使系统重配置托盘/重挂远端场景宿主
//          (v0.0.94 深诊断实锤 dump 瞬间材质容器 h=1、场景宿主 a=0.00 h=1 = 重挂中间态)。
static void HNPMSetAlphaNoAnim(UIView *v, CGFloat a) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    v.layer.opacity = a;
    [CATransaction commit];
}

// v0.0.98: 被动钳制 — 给背景视图挂目标 alpha(associated object), 供 setAlpha: 钩子
//          在系统自己写入时当场钳回目标值(同一调用栈内, 不产生我们的主动写事件)。
static char kHNPMTargetAlphaKey;
static void HNPMMarkTargetAlpha(UIView *v, CGFloat a) {
    objc_setAssociatedObject(v, &kHNPMTargetAlphaKey, a < 0.99 ? @(a) : nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// v0.0.99: 钳制判定共用 — 返回实际应写入的值(需钳制→目标值; 否则原值)。
//          v0.0.98 钳制零命中的最可能原因: MTMaterialView 自己重写了 setAlpha:,
//          系统 reset 走子类实现, 我们只 hook 了 UIView 的实现 → v0.0.99 双 hook。
static CFAbsoluteTime sHNPMCoerceLastLog = 0;
static CGFloat HNPMCoerceAlphaValue(UIView *self, CGFloat a) {
    NSNumber *t = objc_getAssociatedObject(self, &kHNPMTargetAlphaKey);
    if (t) {
        CGFloat target = t.doubleValue;
        if (target < 0.99 && fabs(a - target) > 0.005) {
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (now - sHNPMCoerceLastLog > 1.0) {
                sHNPMCoerceLastLog = now;
                HNPMAppendLog([NSString stringWithFormat:@"[透明] 材质写入钳制 %.2f→%.2f(被动) cls=%@",
                               a, target, NSStringFromClass([self class])]);
            }
            return target;
        }
    }
    return a;
}

static int HNPMPlatterApplyBg(UIView *platter, CGFloat a) {
    int hits = 0;
    NSString *via = @"";
    UIView *bg = HNPMPlatterBgView(platter, &via);
    HNPMMarkTargetAlpha(platter, a);   // v0.0.99: 托盘级也挂目标(backgroundView 被系统替换时就地重申)
    if (bg) {
        HNPMMarkTargetAlpha(bg, a);   // 无论是否需要写, 都让钳制钩子知道目标值
        if (fabs(bg.alpha - a) > 0.01) { HNPMSetAlphaNoAnim(bg, a); hits++; }
    } else {
        // 托盘无背景子层(罕见) → 整托盘淡化(旧路兜底, 内容会连带)
        if (fabs(platter.alpha - a) > 0.01) { HNPMSetAlphaNoAnim(platter, a); hits++; }
    }
    return hits;
}

// ---- v0.1.0: 罩层路线 ----
// v0.0.99 日志裁决: setAlpha:(UIView/MTMaterialView)/setBackgroundView:/recipe 全部拦不到
// 系统重置, 配方 2/3/0 也无原生半透明。唯一没试的路: 完全不碰系统材质 ——
// 把系统材质 hidden, 在其上方插入我们自己的半透明 blur 罩层。
// 系统随便重配置它自己的材质(α=1.0/recipe=1 原生默认, 不触发任何重配置战争),
// 罩层是我们自己的视图, 系统不会动它。诱因链(写入→重建→歌词暗)从根上消失。
// 开关: /var/mobile/Documents/HideNowPlaying.cover 文件存在 = 罩层模式(默认关, 可 A/B)。
#define HNPM_COVER_TAG 0x484E5043   // 'HNPC'
static BOOL sHNPMCoverCached = NO;
static BOOL sHNPMCoverCachedValid = NO;
static CFAbsoluteTime sHNPMCoverCachedAt = 0;
static BOOL HNPMCoverMode(void) {
    if (sHNPMCoverCachedValid && CFAbsoluteTimeGetCurrent() - sHNPMCoverCachedAt < 5.0)
        return sHNPMCoverCached;
    sHNPMCoverCached = [[NSFileManager defaultManager]
        fileExistsAtPath:@"/var/mobile/Documents/HideNowPlaying.cover"];
    sHNPMCoverCachedValid = YES;
    sHNPMCoverCachedAt = CFAbsoluteTimeGetCurrent();
    return sHNPMCoverCached;
}

// v0.1.3: 罩层查找 — 材质的关联罩层 → 兄弟 tag → 祖先托盘的关联罩层
//          (托盘无 bg 期罩层挂在 platter.superview, 关联在托盘上)
static char kHNPMCoverSelfKey;
static UIVisualEffectView *HNPMCoverForView(UIView *mat) {
    UIVisualEffectView *cover = objc_getAssociatedObject(mat, &kHNPMCoverSelfKey);
    if (cover && cover.superview) return cover;
    if (mat.superview) {
        for (UIView *s in mat.superview.subviews) {
            if (s.tag == HNPM_COVER_TAG && [s isKindOfClass:[UIVisualEffectView class]])
                return (UIVisualEffectView *)s;
        }
    }
    Class platterCls = NSClassFromString(@"PLPlatterView");
    UIView *anc = mat.superview;
    int g = 0;
    while (anc && g++ < 6) {
        if (platterCls && [anc isKindOfClass:platterCls])
            return objc_getAssociatedObject(anc, &kHNPMCoverSelfKey);
        anc = anc.superview;
    }
    return nil;
}

// v0.1.11: 找到材质所属托盘内容层的原生 backdrop 渲染器。
//          v0.1.10 日志裁决: 白底期与透明期的视图树逐字节相同(0.3s/0.8s/1.5s 三份 dump
//          完全一致, MTMaterialView h=1/罩层 a=0.20 在场) → 白底→透明的转变发生在渲染
//          内部, 视图层修复不可达。真身 = PLPlatterCustomContentView 内的
//          _UIVisualEffectBackdropView(位于罩层之上, 按原生配方渲染 → 罩层模式下永远白底)。
//          罩层模式设计 = 系统材质整体退场, backdrop 一并中和; 歌词/控件在
//          CSActivityItemContentView(CustomContent 的另一子树), 不受影响。
static UIView *HNPMPlatterBackdropOfMat(UIView *mat) {
    @try {
        Class platterCls = NSClassFromString(@"PLPlatterView");
        Class backdropCls = NSClassFromString(@"_UIVisualEffectBackdropView");
        if (!platterCls || !backdropCls) return nil;
        UIView *platter = mat;
        int g = 0;
        while (platter && g++ < 6) {
            if ([platter isKindOfClass:platterCls]) break;
            platter = platter.superview;
        }
        if (!platter || ![platter isKindOfClass:platterCls]) return nil;
        // v0.1.12: 直接子级迭代改为全子树 DFS + 先 copy — 托盘高频重建期对 subviews
        //          做 for-in 会因并发变异抛 NSException(被 @try 吞掉 → v0.1.11 全场 miss 零日志)。
        NSMutableArray *stack = [NSMutableArray arrayWithObject:platter];
        int guard = 0;
        while (stack.count > 0 && guard++ < 200) {
            UIView *v = stack.firstObject;
            [stack removeObjectAtIndex:0];
            if (!v) continue;
            // v0.1.34: 不下钻自家罩层(tag) — 否则 DFS 先命中罩层内部自己的 backdrop,
            //          既误杀罩层 blur, 也让系统 backdrop 逃过中和(v0.1.12 实际如此)。
            if (v.tag == HNPM_COVER_TAG) continue;
            if ([v isKindOfClass:backdropCls]) return v;
            [stack addObjectsFromArray:[v.subviews copy]];
        }
    } @catch (NSException *e) {}
    return nil;
}

// v0.1.13: backdrop 挂载即中和钩子 — v0.1.12 日志裁决: 首建卡时(配方期) backdrop 尚未
//          创建(中和miss: 托盘子1=[CustomContent]), 系统 ~1s 后惰性补建 backdrop(a=1.0
//          原生材质) → 到下一轮巡检中和之间留下原生渲染窗口 = 用户看到的"歌词闪一下"。
//          解法: hook _UIVisualEffectBackdropView didMoveToWindow, 挂载瞬间归零(赶在渲染前)。
// v0.1.34 收窄: 只中和"直接父级 = PLPlatterCustomContentView"的 backdrop(= v0.1.12 实证
//          无害的材质白底那一个)。v0.1.13 用"祖先命中 PLPlatterView"判定过宽, 把卡内容里
//          渲染歌词/控件的 vibrancy backdrop 也全部归零 → 用户实测整张音乐卡消失。
//          (对照教训: 卡内容文本/控件也靠 effect backdrop 渲染, 一个都不能多杀。)
static void (*sHNPMOrigBackdropDidMove)(id, SEL);
static void hnpmBackdropDidMove(id self, SEL _cmd) {
    sHNPMOrigBackdropDidMove(self, _cmd);
    @try {
        if (![NSThread isMainThread]) return;
        UIView *v = (UIView *)self;
        if (!v || v.alpha < 0.01) return;
        if (!HNPMCoverMode()) return;
        CGFloat a = HNPMBgAlpha();
        if (a >= 0.99) return;
        Class customCls = NSClassFromString(@"PLPlatterCustomContentView");
        if (!customCls) return;
        UIView *p = v.superview;
        if (!p || p.tag == HNPM_COVER_TAG) return;         // 自家罩层的 backdrop, 不碰
        if (![p isKindOfClass:customCls]) return;          // 只中和材质白底(直接子级)
        HNPMSetAlphaNoAnim(v, 0.0);
        HNPMAppendLog(@"[透明·罩层] backdrop 挂载即中和(挂载钩子)");
    } @catch (NSException *e) {}
}
static void HNPMHookBackdrop(void) {
    @try {
        Class bdCls = objc_getClass("_UIVisualEffectBackdropView");
        if (!bdCls) { HNPMAppendLog(@"[透明·罩层] 挂载钩子未挂(类未加载, 依赖巡检兜底)"); return; }
        SEL sel = @selector(didMoveToWindow);
        Method m = class_getInstanceMethod(bdCls, sel);
        if (!m) { HNPMAppendLog(@"[透明·罩层] 挂载钩子未挂(无 didMoveToWindow)"); return; }
        sHNPMOrigBackdropDidMove = (void (*)(id, SEL))method_getImplementation(m);
        method_setImplementation(m, (IMP)hnpmBackdropDidMove);
        HNPMAppendLog(@"[透明·罩层] backdrop 挂载钩子已挂(didMoveToWindow)");
    } @catch (NSException *e) {}
}

// 对单个系统材质层应用罩层(创建/校位/校 alpha/按需隐藏材质), 返回实际改动数。
// v0.1.1 泛化: 材质层不限于托盘背景 — 亮屏重建序列里系统会先给卡内放一个
//          UIVisualEffectView 白底(托盘惰性创建晚 ~1s), 罩层必须也能盖住它。
// v0.1.3: bg 材质本身也是惰性创建(亮屏 dump 实锤: 卡/托盘 0.3s 已在窗口, bg 晚 ~1s,
//          期间白底来自托盘自身渲染) → hideMat=NO 模式直接盖托盘: 罩层插在
//          platter.superview 里托盘正上方(内容是托盘的兄弟层, 不受影响), 托盘不隐藏;
//          bg 一出现, 同一罩层经 HNPMCoverForView 祖先链找到后移入托盘内盖上 bg。
static int HNPMCoverApplyOnMaterial(UIView *mat, CGFloat a, BOOL hideMat) {
    int hits = 0;
    @try {
        if (!mat || !mat.superview) return 0;
        UIView *parent = mat.superview;
        UIVisualEffectView *cover = HNPMCoverForView(mat);
        if (!cover) {
            UIBlurEffect *eff = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial];
            cover = [[UIVisualEffectView alloc] initWithEffect:eff];
            cover.tag = HNPM_COVER_TAG;
            objc_setAssociatedObject(mat, &kHNPMCoverSelfKey, cover, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [parent insertSubview:cover aboveSubview:mat];
            HNPMAppendLog([NSString stringWithFormat:@"[透明·罩层] 已创建 blur 罩层 a=%.2f(材质%@%@)",
                           a, NSStringFromClass([mat class]),
                           hideMat ? @"已隐藏" : @", 盖托盘层(无bg期, 内容不受影响)"]);
            hits++;
        } else if (cover.superview != parent) {
            [parent insertSubview:cover aboveSubview:mat];   // 移入当前父视图(bg 出现后从托盘上层移入)
            hits++;
        }
        // 系统重建材质时新层可能插到罩层之下 → 每次应用保证罩层在材质正上方 + 帧同步
        NSUInteger ci = [parent.subviews indexOfObject:cover];
        NSUInteger mi = [parent.subviews indexOfObject:mat];
        if (mi == NSNotFound || ci == NSNotFound || ci < mi) {
            [parent insertSubview:cover aboveSubview:mat];
            hits++;
        }
        if (!CGRectEqualToRect(cover.frame, mat.frame)) {
            cover.frame = mat.frame;
            cover.autoresizingMask = mat.autoresizingMask;
            cover.layer.cornerRadius = hideMat ? mat.layer.cornerRadius : 0.0;
            cover.layer.masksToBounds = YES;
            hits++;
        }
        if (fabs(cover.alpha - a) > 0.01) { HNPMSetAlphaNoAnim(cover, a); hits++; }
        if (hideMat && !mat.hidden) { mat.hidden = YES; hits++; }
        // v0.1.11: 罩层模式下中和内容层 backdrop(白底真身, 渲染内部状态, 视图层盖不住)
        if (a < 0.99) {
            UIView *bd = HNPMPlatterBackdropOfMat(mat);
            if (bd && bd.alpha > 0.01) {
                HNPMSetAlphaNoAnim(bd, 0.0);
                HNPMAppendLog(@"[透明·罩层] 已中和 PLPlatterCustomContentView backdrop(白底真身退场)");
                hits++;
            } else if (!bd) {
                // v0.1.12: miss 诊断(限频 1s) — 报告查找失败在哪一环, 消灭静默失败
                static CFAbsoluteTime sHNPMBackDropMissAt = 0;
                CFAbsoluteTime nnow = CFAbsoluteTimeGetCurrent();
                if (nnow - sHNPMBackDropMissAt > 1.0) {
                    sHNPMBackDropMissAt = nnow;
                    @try {
                        Class pCls = NSClassFromString(@"PLPlatterView");
                        UIView *p = mat;
                        int gg = 0;
                        BOOL fp = NO;
                        while (p && gg++ < 6) {
                            if (pCls && [p isKindOfClass:pCls]) { fp = YES; break; }
                            p = p.superview;
                        }
                        NSMutableString *info = [NSMutableString stringWithFormat:@"mat=%@ 托盘=%d",
                                                 NSStringFromClass([mat class]), fp ? 1 : 0];
                        if (fp) {
                            NSArray *kids = [p.subviews copy];
                            [info appendFormat:@" 子%d:[", (int)kids.count];
                            for (UIView *c in kids) [info appendFormat:@"%@,", NSStringFromClass([c class])];
                            [info appendString:@"]"];
                        }
                        HNPMAppendLog([NSString stringWithFormat:@"[透明·罩层·中和miss] %@", info]);
                    } @catch (NSException *e) {}
                }
            }
        }
    } @catch (NSException *e) {}
    return hits;
}

// 对单个托盘应用罩层: 有 bg 盖 bg(隐藏); 无 bg(惰性创建期)直接盖托盘(不隐藏托盘/内容)
static int HNPMPlatterApplyCover(UIView *platter, CGFloat a) {
    UIView *bg = HNPMPlatterBgView(platter, NULL);
    if (bg) return HNPMCoverApplyOnMaterial(bg, a, YES);
    return HNPMCoverApplyOnMaterial(platter, a, NO);
}

// v0.1.7 前置声明(v0.1.8 定义): 连扫帧内节流调用, 兜住登记缝隙期外的重建
// v0.1.34: 卡区记忆(最近一次登记媒体卡 cell 的窗口坐标) — 持续生效版(v0.1.34)的避让依据
static CGRect sHNPMCardRegion33 = {{0, 0}, {0, 0}};

// v0.1.34: 用户裁决"让透明度一直生效" — 白底=调整透明度后亮屏首帧配方未生效(用户观察,
//          与日志互斥证据吻合: 白底盘次 cell 未创建, 占位材质从未被配方覆盖)。
//          v0.1.34 的白窗内临时避让升级为**持续生效**: 0.5s 一拍, 最近登记卡区内的
//          BSUIVibrancyBackdrop/AnimatingPortal 只要可见就压住; 覆盖开关关闭时恢复。
//          宿主本身绝不隐藏(时钟安全, v0.1.31 教训); 全屏 ShadowView 不碰(无法隔离卡区)。
static NSHashTable *sHNPMCaptureHiddenViews = nil;   // 弱引用: 我们隐藏的快照材质

static void HNPMCapturePersistOnce(void) {
    @try {
        BOOL on = HNPMCoverMode();
        if (sHNPMCaptureHiddenViews == nil)
            sHNPMCaptureHiddenViews = [NSHashTable weakObjectsHashTable];
        for (UIView *hv in [sHNPMCaptureHiddenViews copy]) {
            if (!on || !hv.window) {           // 开关关闭/视图离场 → 恢复
                hv.hidden = NO;
                [sHNPMCaptureHiddenViews removeObject:hv];
            }
        }
        if (!on || CGRectIsEmpty(sHNPMCardRegion33)) return;
        int n = 0;
        NSArray *windows = [UIApplication sharedApplication].windows;
        for (UIWindow *w in windows) {
            if (!w) continue;
            NSMutableArray *stack = [NSMutableArray arrayWithObject:w];
            int guard = 0;
            while (stack.count > 0 && guard++ < 600) {
                UIView *v = stack.firstObject;
                [stack removeObjectAtIndex:0];
                if (!v || v.tag == HNPM_COVER_TAG) continue;
                NSString *cls = NSStringFromClass([v class]);
                if ([cls containsString:@"CaptureOnly"]) {
                    [stack addObjectsFromArray:v.subviews];   // 只下钻宿主, 绝不隐藏宿主本身
                    continue;
                }
                if (![cls hasPrefix:@"BSUIVibrancyBackdrop"] && ![cls hasPrefix:@"BSUIVibrancyAnimatingPortal"]) {
                    [stack addObjectsFromArray:v.subviews];
                    continue;
                }
                // 命中: 与卡区相交才隐藏(时钟在屏幕上方, frame 不相交)
                CGRect vf = [v convertRect:v.bounds toView:nil];
                CGRect inter = CGRectIntersection(vf, sHNPMCardRegion33);
                if (CGRectIsNull(inter) || CGRectIsEmpty(inter) || v.hidden || v.alpha < 0.01) continue;
                v.hidden = YES;
                [sHNPMCaptureHiddenViews addObject:v];
                n++;
            }
        }
        if (n > 0)
            HNPMAppendLog([NSString stringWithFormat:
                @"[透明·罩层] 已隐卡区捕获快照 %d 处(持续生效)", n]);
    } @catch (NSException *e) {}
}

static void HNPMCapturePersistLoop(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ HNPMCapturePersistLoop(); });
        return;
    }
    HNPMCapturePersistOnce();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try { HNPMCapturePersistLoop(); } @catch (NSException *e) {}
    });
}

// v0.1.44: CaptureOnly 宿主完整解剖 — v0.1.43 侦察实锤: NCMaterialDisplayingCapture-
//          OnlyViewControllerView 常驻 SBCoverSheetWindow(393x852@0,0 a=1.00 h=0 全屏,
//          与卡区相交, 96 条侦察行全程在案), 但钉扎 0 命中(宿主内无 BSUIVibrancy* 类
//          可压) → 白底要么是宿主自身材质层(它是 NCMaterial*View 材质视图), 要么是
//          宿主内其他类名的子层。本版亮/灭屏 +0.05s 对该宿主做一次完整 DFS 解剖:
//          类名/frame/alpha/hidden/背景色(view+layer), 上限 48 行 — 看清内部后精打。
static void HNPMCaptureHostAutopsy(NSString *tag) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ HNPMCaptureHostAutopsy(tag); });
        return;
    }
    @try {
        UIView *host = nil;
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (!w) continue;
            NSMutableArray *stack = [NSMutableArray arrayWithObject:w];
            int guard = 0;
            while (stack.count > 0 && guard++ < 1500 && !host) {
                UIView *v = stack.firstObject;
                [stack removeObjectAtIndex:0];
                if (!v) continue;
                if ([NSStringFromClass([v class]) containsString:@"CaptureOnly"]) { host = v; break; }
                [stack addObjectsFromArray:v.subviews];
            }
            if (host) break;
        }
        if (!host) {
            HNPMAppendLog([NSString stringWithFormat:@"[宿主解剖@%@] 无 CaptureOnly 宿主在场", tag]);
            return;
        }
        NSMutableArray *rows = [NSMutableArray array];
        NSMutableArray *stack = [NSMutableArray arrayWithObject:host];
        int guard = 0;
        while (stack.count > 0 && guard++ < 400 && rows.count < 48) {
            UIView *v = stack.firstObject;
            [stack removeObjectAtIndex:0];
            if (!v) continue;
            NSString *cls = NSStringFromClass([v class]);
            CGRect vf = [v convertRect:v.bounds toView:nil];
            NSString *bg = v.backgroundColor ? HNPMCGColorDesc(v.backgroundColor.CGColor) : @"nil";
            NSString *lbg = v.layer.backgroundColor ? HNPMCGColorDesc(v.layer.backgroundColor) : @"nil";
            CALayer *pl = (CALayer *)v.layer.presentationLayer;
            CGFloat pop = pl ? pl.opacity : -1.0;
            [rows addObject:[NSString stringWithFormat:@"%@ %.0fx%.0f@%.0f,%.0f a=%.2f p=%.2f h=%d bg=%@ lbg=%@",
                             cls, vf.size.width, vf.size.height, vf.origin.x, vf.origin.y,
                             v.alpha, pop, v.hidden ? 1 : 0, bg, lbg]];
            [stack addObjectsFromArray:v.subviews];
        }
        HNPMAppendLog([NSString stringWithFormat:@"[宿主解剖@%@] %lu行: %@", tag,
                       (unsigned long)rows.count, [rows componentsJoinedByString:@" || "]]);
    } @catch (NSException *e) {}
}

// v0.1.43: AOD 捕获层侦察+钉扎 — 根因坐实: 白底 = AOD(始终显示)灭屏时独立渲染的音乐卡
//          材质, 亮屏过渡瞬间闪现(用户关闭 AOD 白底消失实测)。AOD 捕获宿主
//          (NCMaterialDisplayingCaptureOnlyViewControllerView, v0.1.30 唯一一次在案)
//          不在常规巡检时机在场 → 本版亮/灭屏后 +0.02/0.05/0.1/0.2/0.4/0.8s 高频扫:
//          ①CaptureOnly 命中→立即钉扎宿主内与卡区相交的 BSUIVibrancyBackdrop/Portal
//          ②与卡区记忆相交的顶层 BSUIVibrancy* → 直接压(同 PersistOnce 判定)
//          ③AOD/AlwaysOn/Idle 关键词命中→侦察记录(类名/窗口/frame/hidden), 下版精打
//          全树无 hidden 剪枝(捕获快照视图常以 hidden 态预渲染)。
static void HNPMCaptureHostPin(UIView *host, NSString *tag);   // 前向声明(v0.1.36 定义于后)
static NSString *HNPMCGColorDesc(CGColorRef c);   // 前向声明(v0.1.44 宿主解剖用, 定义于后)

static void HNPMCaptureSweep(NSString *tag) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ HNPMCaptureSweep(tag); });
        return;
    }
    @try {
        if (!HNPMCoverMode() || CGRectIsEmpty(sHNPMCardRegion33)) return;
        if (sHNPMCaptureHiddenViews == nil)
            sHNPMCaptureHiddenViews = [NSHashTable weakObjectsHashTable];
        int capCount = 0, pinCount = 0;
        NSMutableArray *rows = [NSMutableArray array];
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (!w) continue;
            NSMutableArray *stack = [NSMutableArray arrayWithObject:w];
            int guard = 0;
            while (stack.count > 0 && guard++ < 1200) {
                UIView *v = stack.firstObject;
                [stack removeObjectAtIndex:0];
                if (!v || v.tag == HNPM_COVER_TAG) continue;
                NSString *cls = NSStringFromClass([v class]);
                CGRect vf = [v convertRect:v.bounds toView:nil];
                CGRect inter = CGRectIntersection(vf, sHNPMCardRegion33);
                BOOL inCard = !CGRectIsNull(inter) && !CGRectIsEmpty(inter);
                BOOL isCap = [cls containsString:@"CaptureOnly"];
                BOOL isAODkw = [cls containsString:@"AlwaysOn"] ||
                               [cls containsString:@"AOD"] ||
                               [cls rangeOfString:@"Idle" options:NSCaseInsensitiveSearch].location != NSNotFound;
                BOOL isVib = [cls hasPrefix:@"BSUIVibrancyBackdrop"] ||
                             [cls hasPrefix:@"BSUIVibrancyAnimatingPortal"];
                if (isCap || isAODkw || (isVib && inCard)) {
                    if (rows.count < 20)
                        [rows addObject:[NSString stringWithFormat:
                            @"%@|win=%@ %.0fx%.0f@%.0f,%.0f a=%.2f h=%d 卡区=%d",
                            cls, NSStringFromClass([w class]),
                            vf.size.width, vf.size.height, vf.origin.x, vf.origin.y,
                            v.alpha, v.hidden ? 1 : 0, inCard ? 1 : 0]];
                }
                if (isCap) {                       // 宿主绝不隐藏, 钉扎其内卡区 backdrop
                    HNPMCaptureHostPin(v, tag);
                    capCount++;
                } else if (isVib && inCard && !v.hidden && v.alpha > 0.01) {
                    v.hidden = YES;                // 顶层独立 Vibrancy 与卡区相交 → 压
                    [sHNPMCaptureHiddenViews addObject:v];
                    pinCount++;
                }
                [stack addObjectsFromArray:v.subviews];
            }
        }
        if (rows.count > 0)
            HNPMAppendLog([NSString stringWithFormat:@"[AOD侦察@%@] %lu处: %@", tag,
                           (unsigned long)rows.count, [rows componentsJoinedByString:@" || "]]);
        if (capCount > 0 || pinCount > 0)
            HNPMAppendLog([NSString stringWithFormat:
                @"[AOD侦察@%@] 钉扎: CaptureOnly宿主 %d 个, 顶层卡区Vibrancy %d 处", tag, capCount, pinCount]);
    } @catch (NSException *e) {}
}

// v0.1.36: 捕获时刻钉扎 — v0.1.35 探针裁决(42 条探针逐卡区过滤): 白窗期间进程内
//          全窗口/全树(view+layer)与卡区相交的只有全屏壁纸材质与 57x40 小元素,
//          没有任何卡区尺寸的白底画手; CaptureOnly 宿主也从未出现在枚举/探针里
//          → 白底是跨进程上屏的捕获快照, 轮询(0.5s 节拍/探针 0.05~0.35s)追不上
//          它的生存期。改为钩住宿主类自身生命周期: 它一露头(didMoveToWindow/
//          didMoveToSuperview/layoutSubviews)就从宿主根下钻, 把与卡区记忆相交的
//          BSUIVibrancyBackdrop/AnimatingPortal 压住(宿主绝不隐藏, 时钟安全),
//          让"拍进去"的快照天生透明; 再补 +0.05/+0.15 两拍防捕获晚于首次布局。
//          共用 sHNPMCaptureHiddenViews 弱引用表 → 开关关闭/离场自动恢复。
static void HNPMCaptureHostPin(UIView *host, NSString *tag) {
    if (!host || !HNPMCoverMode() || CGRectIsEmpty(sHNPMCardRegion33)) return;
    if (sHNPMCaptureHiddenViews == nil)
        sHNPMCaptureHiddenViews = [NSHashTable weakObjectsHashTable];
    int n = 0;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:host];
    int guard = 0;
    while (stack.count > 0 && guard++ < 600) {
        UIView *v = stack.firstObject;
        [stack removeObjectAtIndex:0];
        if (!v) continue;
        NSString *cls = NSStringFromClass([v class]);
        if (![cls hasPrefix:@"BSUIVibrancyBackdrop"] && ![cls hasPrefix:@"BSUIVibrancyAnimatingPortal"]) {
            [stack addObjectsFromArray:v.subviews];   // 一路下钻, 宿主本身不隐藏
            continue;
        }
        CGRect vf = [v convertRect:v.bounds toView:nil];
        CGRect inter = CGRectIntersection(vf, sHNPMCardRegion33);
        if (CGRectIsNull(inter) || CGRectIsEmpty(inter) || v.hidden || v.alpha < 0.01) continue;
        v.hidden = YES;
        [sHNPMCaptureHiddenViews addObject:v];
        n++;
    }
    if (n > 0)
        HNPMAppendLog([NSString stringWithFormat:
            @"[透明·罩层] 已隐卡区捕获快照 %d 处(捕获时刻@%@)", n, tag]);
}

static void HNPMCaptureHostPinDelayed(UIView *host, NSString *tag) {
    if (!host) return;
    __weak UIView *wh = host;
    NSString *t = [tag copy];
    for (NSString *d in @[@"0.05", @"0.15"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                       (int64_t)([d doubleValue] * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try {
                UIView *s = wh;
                if (s && s.window) HNPMCaptureHostPin(s, [NSString stringWithFormat:@"%@+%@", t, d]);
            } @catch (NSException *e) {}
        });
    }
}

static void HNPMCoversWakeSweep(void);

// v0.1.9 前置声明(定义在罩层收集区): 直扫按单元格整体收集目标要用
static void HNPMCoverCollectTargets(UIView *root, NSMutableArray *outTargets);

// v0.1.9: 免登记亮屏扫 — v0.1.8 日志裁决: 直扫"免登记直接应用"零次出现, 每次亮屏新罩层
//          都在 +0.9s 才由布局钩子创建 → 亮屏后 0~0.9s 的白底来自**托盘创建之前的占位
//          效果视图**(v0.1.1 已实锤: 系统先给卡内放一个 UIVisualEffectView 白底, 托盘
//          惰性创建晚 ~1s), 而直扫只找 PLPlatterView, 对占位白底视而不见。
//          解法: 按单元格整体处理 — 找到过关的 NCNotificationListCell(媒体尺寸/未挂窗/
//          空框且未隐藏) 直接走 HNPMCoverCollectTargets(登记路径同款, 同时覆盖托盘/bg/
//          占位 EFX); 构建期还没接进 cell 的托盘按祖先 SupplementaryHostingView/Cell 兜底。
//          应用幂等; 加限频诊断行(窗口/托盘/单元/命中计数), 下次排障有据可查。
static void HNPMCoversWakeSweep(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ HNPMCoversWakeSweep(); });
        return;
    }
    @try {
        CGFloat a = HNPMBgAlpha();
        if (!HNPMCoverMode() || a >= 0.99) return;
        Class platterCls = NSClassFromString(@"PLPlatterView");
        Class hostCls = NSClassFromString(@"NCNotificationListSupplementaryHostingView");
        Class cellCls = NSClassFromString(@"NCNotificationListCell");
        if (!platterCls) return;
        HNPMCapturePersistOnce();   // v0.1.34: 持续生效 — 亮屏扫顺手压一次(幂等)
        NSArray *windows = [UIApplication sharedApplication].windows;
        int hits = 0, nPlatter = 0, nCell = 0, nGated = 0;
        UIView *dumpCell = nil;
        NSMutableArray *cellSizes = [NSMutableArray array];
        for (UIWindow *w in windows) {
            if (!w) continue;
            NSMutableArray *stack = [NSMutableArray arrayWithObject:w];
            int guard = 0;
            while (stack.count > 0 && guard++ < 400) {
                UIView *v = stack.firstObject;
                [stack removeObjectAtIndex:0];
                if (!v) continue;
                NSString *cls = NSStringFromClass([v class]);
                if ([cls containsString:@"Remote"]) continue;
                if (v.tag == HNPM_COVER_TAG) continue;
                if (cellCls && [v isKindOfClass:cellCls]) {
                    nCell++;
                    if (cellSizes.count < 3) {
                        [cellSizes addObject:[NSString stringWithFormat:@"%.0fx%.0f%@",
                            v.frame.size.width, v.frame.size.height, v.hidden ? @"隐" : @""]];
                    }
                    if (!dumpCell && ![hnpmCardCells containsObject:v] &&
                        HNPMCellMediaContent(v, 120)) dumpCell = v;
                    // v0.1.10: 门槛放宽 — 除 150 尺寸外, 含 365x130+ 媒体内容视图的单元也算卡
                    //          (v0.1.9 实测正在播放内容视图可能只有 143 高, 150 分界线误杀)
                    BOOL ok = !v.hidden &&
                              (HNPMIsMediaSized(v.frame.size) ||
                               HNPMCellMediaContent(v, 130) != nil ||
                               !v.window || CGRectIsEmpty(v.frame));
                    if (ok) {
                        nGated++;
                        if (![hnpmCardCells containsObject:v]) [hnpmCardCells addObject:v];
                        {   // v0.1.34: 记录卡区(窗口坐标) — 白底盘次 cell 未创建时的避让依据
                            CGRect cf = [v convertRect:v.bounds toView:nil];
                            if (!CGRectIsEmpty(cf)) sHNPMCardRegion33 = cf;
                        }
                        // 登记路径同款目标收集: 托盘/bg/占位 EFX 一网打尽
                        NSMutableArray *targets = [NSMutableArray array];
                        HNPMCoverCollectTargets(v, targets);
                        for (UIView *mat in targets) {
                            hits += HNPMCoverApplyOnMaterial(mat, a,
                                    !(platterCls && [mat isKindOfClass:platterCls]));
                        }
                    }
                    continue;   // cell 子树已由 collect 遍历(或判定不过关不碰), 不再下钻
                }
                if ([v isKindOfClass:platterCls]) {
                    nPlatter++;
                    // 构建期托盘可能还没接进 cell: 祖先 SupplementaryHostingView 即命中
                    UIView *p = v.superview;
                    BOOL ok = NO;
                    int g2 = 0;
                    while (p && g2++ < 12) {
                        if (hostCls && [p isKindOfClass:hostCls]) { ok = YES; break; }
                        if (cellCls && [p isKindOfClass:cellCls]) {
                            ok = !p.hidden &&
                                 (HNPMIsMediaSized(p.frame.size) || !p.window || CGRectIsEmpty(p.frame));
                            break;
                        }
                        p = p.superview;
                    }
                    if (ok) {
                        nGated++;
                        hits += HNPMPlatterApplyCover(v, a);
                    }
                    continue;   // 托盘内不再下钻(bg 由 HNPMPlatterApplyCover 处理)
                }
                [stack addObjectsFromArray:v.subviews];
            }
        }
        // 诊断: 限频 0.5s — 每次亮屏窗口输出 ~5 行, 记录直扫看到了什么
        static CFAbsoluteTime sHNPMCoversSweepDiag = 0;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - sHNPMCoversSweepDiag > 0.5) {
            sHNPMCoversSweepDiag = now;
            HNPMAppendLog([NSString stringWithFormat:@"[透明·亮屏扫] 窗口%lu 托盘%d 单元%d[%@] 过门%d 改动%d",
                           (unsigned long)windows.count, nPlatter, nCell,
                           [cellSizes componentsJoinedByString:@","], nGated, hits]);
        }
        if (hits > 0) {
            HNPMAppendLog([NSString stringWithFormat:@"[透明·亮屏扫] 免登记直接应用 %d 处罩层", hits]);
            HNPMStartAlphaBurst();
        }
        // 一次性诊断(v0.1.10): 含媒体内容(>=120 高)的未登记单元格 → dump 卡体看白底来源
        static CFAbsoluteTime sHNPMNewCellDumpAt = 0;
        if (dumpCell && now - sHNPMNewCellDumpAt > 5.0) {
            sHNPMNewCellDumpAt = now;
            NSMutableArray *rows = [NSMutableArray array];
            NSMutableArray *st = [NSMutableArray arrayWithObject:dumpCell];
            int g3 = 0;
            while (st.count > 0 && g3++ < 60 && rows.count < 24) {
                UIView *v = st.firstObject;
                [st removeObjectAtIndex:0];
                if (!v) continue;
                NSString *bgMark = (v.layer.backgroundColor != nil) ? @" bg" : @"";
                NSString *efxMark = [v isKindOfClass:[UIVisualEffectView class]] ? @" <EFX>" : @"";
                [rows addObject:[NSString stringWithFormat:@"%@ a=%.2f h=%d%@%@ %.0fx%.0f",
                                 NSStringFromClass([v class]), v.alpha, v.hidden ? 1 : 0,
                                 bgMark, efxMark, v.frame.size.width, v.frame.size.height]];
                [st addObjectsFromArray:v.subviews];
            }
            HNPMAppendLog([NSString stringWithFormat:@"[透明·亮屏扫·卡体] 单元%.0fx%.0f %lu视图: %@",
                           dumpCell.frame.size.width, dumpCell.frame.size.height,
                           (unsigned long)rows.count, [rows componentsJoinedByString:@" || "]]);
        }
    } @catch (NSException *e) {}
}

// v0.1.8: 亮屏后时序化直扫 — 新单元格/背景在亮屏后 ~1s 内分批出现(配方序列实测),
//          0.05~2.5s 各扫一次, 任一次命中即把白底窗口压到 ≤50ms。
static void HNPMScheduleWakeSweeps(void) {
    for (NSString *d in @[@"0.05", @"0.15", @"0.3", @"0.5", @"0.75", @"1.0", @"1.5", @"2.0", @"2.5"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)([d doubleValue] * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ @try { HNPMCoversWakeSweep(); } @catch (NSException *e) {} });
    }
}

// v0.1.3: 托盘离开窗口时摘掉罩层(无bg期罩层挂在 platter.superview, 托盘被移除会变孤儿)
// v0.1.9: 加日志 — 排查亮屏重建序列是否在拆罩层(白底窗口期罩层去向的关键证据)
static void HNPMCoverDetach(UIView *platter) {
    @try {
        UIVisualEffectView *cover = objc_getAssociatedObject(platter, &kHNPMCoverSelfKey);
        if (cover) { [cover removeFromSuperview]; objc_setAssociatedObject(platter, &kHNPMCoverSelfKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
        int removed = cover ? 1 : 0;
        for (UIView *s in platter.subviews) {
            if (s.tag == HNPM_COVER_TAG) { [s removeFromSuperview]; removed++; }
        }
        if (removed > 0) {
            static CFAbsoluteTime sHNPMCoverDetachLog = 0;
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (now - sHNPMCoverDetachLog > 0.5) {
                sHNPMCoverDetachLog = now;
                HNPMAppendLog([NSString stringWithFormat:@"[透明·罩层] 摘除 %d 处(托盘离开窗口)", removed]);
            }
        }
    } @catch (NSException *e) {}
}

// v0.1.0: 恢复原生(alpha 调回 1.0 / 功能关闭时) — 露出系统材质, 隐藏罩层
static void HNPMCoverRestoreAll(UIView *root) {
    if (![NSThread isMainThread]) return;
    @try {
        Class platterCls = NSClassFromString(@"PLPlatterView");
        NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
        int guard = 0;
        while (stack.count > 0 && guard++ < 200) {
            UIView *v = stack.firstObject;
            [stack removeObjectAtIndex:0];
            if (!v) continue;
            if ([NSStringFromClass([v class]) containsString:@"Remote"]) continue;
            // v0.1.1: 任意挂了罩层的材质层(托盘背景/卡内效果视图/无bg期托盘) → 露出材质, 隐藏罩层
            UIVisualEffectView *cover = objc_getAssociatedObject(v, &kHNPMCoverSelfKey);
            if (cover) {
                if (!cover.hidden) cover.hidden = YES;
                BOOL isPlatter = platterCls && [v isKindOfClass:platterCls];
                if (!isPlatter && v.hidden) v.hidden = NO;   // 托盘从未隐藏, 不动
            }
            [stack addObjectsFromArray:v.subviews];
        }
    } @catch (NSException *e) {}
}

// v0.1.1: 收集罩层目标 — 托盘背景子层 + 卡内系统效果视图(托盘缺席时的白底),
//          排除我们自己的罩层(同为 UIVisualEffectView, 按 tag/关联排除)
static void HNPMCoverCollectTargets(UIView *root, NSMutableArray *outTargets) {
    @try {
        Class platterCls = NSClassFromString(@"PLPlatterView");
        if (!platterCls) return;
        NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
        int guard = 0;
        while (stack.count > 0 && guard++ < 200) {
            UIView *v = stack.firstObject;
            [stack removeObjectAtIndex:0];
            if (!v) continue;
            NSString *cls = NSStringFromClass([v class]);
            if ([cls containsString:@"Remote"]) continue;
            if (v.tag == HNPM_COVER_TAG) continue;   // 自家罩层不是目标
            if ([v isKindOfClass:platterCls]) {
                UIView *bg = HNPMPlatterBgView(v, NULL);
                // v0.1.3: bg 惰性创建期以托盘为目标(罩层盖托盘层, 不隐藏); bg 就绪后以 bg 为目标
                [outTargets addObject:bg ? bg : v];
                continue;   // 托盘内不再下钻
            }
            if ([v isKindOfClass:[UIVisualEffectView class]]) {
                [outTargets addObject:v];
                continue;   // 效果视图内部(effectView.contentView)不下钻
            }
            [stack addObjectsFromArray:v.subviews];
        }
    } @catch (NSException *e) {}
}

// v0.1.3: 罩层漂移检测(只读) — 目标(bg 或无bg期的托盘)无罩/罩层 alpha 偏/罩层不在其上方
static BOOL HNPMPlatterCoverDrift(UIView *platter, CGFloat a) {
    UIView *bg = HNPMPlatterBgView(platter, NULL);
    UIView *mat = bg ? bg : platter;   // v0.1.3: bg 缺席时以托盘为覆盖目标
    UIVisualEffectView *cover = HNPMCoverForView(mat);
    if (!cover) return YES;
    if (fabs(cover.alpha - a) > 0.01) return YES;
    UIView *parent = cover.superview;
    if (!parent) return YES;
    NSUInteger ci = [parent.subviews indexOfObject:cover];
    NSUInteger mi = [parent.subviews indexOfObject:mat];
    if (mi == NSNotFound || ci == NSNotFound || ci < mi) return YES;   // 罩层必须在其正上方
    // v0.1.8: 无bg期罩层可能在托盘零框时创建(亮屏直扫早于首次布局) → 框不齐也算漂移,
    //         让布局/直扫路径把 frame 补齐到材质当前框
    if (!CGRectEqualToRect(cover.frame, mat.frame)) return YES;
    return NO;
}

// v0.0.92: 只读漂移检测 — 布局/挂载回调里的同步写 alpha 会与系统材质渲染管线打架:
//          真机对照实锤(v0.0.91): 关闭插件(HideNowPlaying.off)亮屏进度条无延迟, 开启则 ~1s 滞后;
//          时间线与 v0.0.88 引入的"布局回调内同步写"重合 → 该写入挤掉远端内容更新。
//          故 hook 回调只侦测, 写入全部收敛到连扫窗口的帧边界。
static BOOL HNPMPlatterBgDrift(UIView *platter, CGFloat a) {
    UIView *bg = HNPMPlatterBgView(platter, NULL);
    CGFloat cur = bg ? bg.alpha : platter.alpha;
    return fabs(cur - a) > 0.01;
}

// v0.0.88: 亮屏重申 — 真机实锤: 锁屏亮屏后系统会重建/重置锁屏托盘(PLPlatterView),
//          背景透明度被冲回 1.0, 而旧逻辑只在登记/恢复/1s重试路径重申 → 亮屏后约 1s 才变透。
// v0.0.92: 改为只侦测不写(原因见 HNPMPlatterBgDrift 注释) — 发现漂移只开连扫窗口,
//          下一帧在帧边界修正(视觉无差, 布局回调内零写入)。
static void HNPMPlatterReapplyOnLayout(UIView *platter) {
    if (![NSThread isMainThread]) return;
    @try {
        CGFloat a = HNPMBgAlpha();
        if (a >= 0.99) return;   // 1.0 = 功能关闭(罩层恢复由登记路径 HNPMCoverRestoreAll 兜底)
        // 只处理已登记卡的托盘: 沿祖先链找登记表命中(≤12 级足够)
        UIView *p = platter;
        UIView *cell = nil;
        int guard = 0;
        while (p && guard++ < 12) {
            if ([hnpmCardCells containsObject:p]) { cell = p; break; }
            p = p.superview;
        }
        if (!cell || cell.hidden || HNPMCardHiddenGet(cell) || !cell.window) {
            // v0.1.2: 托盘挂载可能早于内容视图(内容视图钩子才预登记) → 此处按类预登记,
            //         让连扫在读函数里尽早看到该卡(罩层模式首帧即修, 不等 0.3s 登记)
            if (cell || HNPMCoverMode()) {
                Class cellCls = NSClassFromString(@"NCNotificationListCell");
                UIView *p0 = platter;
                int g2 = 0;
                while (p0 && g2++ < 12 && ![p0 isKindOfClass:cellCls]) p0 = p0.superview;
                if (p0 && HNPMIsMediaSized(p0.frame.size) && p0.window && !p0.hidden) {
                    [hnpmCardCells addObject:p0];
                    cell = p0;
                }
            }
        }
        if (!cell || cell.hidden || HNPMCardHiddenGet(cell) || !cell.window) return;
        // v0.1.0: 罩层模式用罩层漂移检测(材质被露出/罩层丢失/alpha 偏)
        BOOL drift = HNPMCoverMode() ? HNPMPlatterCoverDrift(platter, a)
                                     : HNPMPlatterBgDrift(platter, a);
        if (drift) {
            // v0.1.4: 罩层模式下就地应用(罩层是我们自己的视图, 应用它不触碰系统材质,
            //         不违反 v0.0.92 的"布局钩子只侦测"原则 — 该原则针对系统材质写入)
            if (HNPMCoverMode()) HNPMPlatterApplyCover(platter, a);
            HNPMStartAlphaBurst();
        }
    } @catch (NSException *e) {}
}

// v0.0.89: 即时透明 — 亮屏时序实锤(v0.0.88 真机日志): 系统重建卡片 → 托盘首次布局时
//          单元格尚未登记(登记走 0.3s 延迟) → hook 跳过 → 用户看到 ~1s 不透明。
//          这里做两件事: ①挂载瞬间预登记合格单元格(尺寸门槛当场可判, 登记幂等) —
//          让托盘 hook 在首次布局就命中; ②托盘已存在时立即压 alpha(无兜底无重试,
//          托盘未建好则等 hook/登记路径, 不做整卡淡化避免文字闪烁)。
static int HNPMInstantPlatterAlpha(UIView *cell) {
    if (![NSThread isMainThread]) return 0;
    @try {
        CGFloat a = HNPMBgAlpha();
        if (a >= 0.99) return 0;
        if (cell.hidden || HNPMCardHiddenGet(cell)) return 0;
        // v0.1.1: 罩层模式 — 目标含托盘背景与卡内效果视图(托盘缺席时的白底),
        //          挂载瞬间即可盖住, 不必等惰性托盘创建(~1s)
        if (HNPMCoverMode()) {
            NSMutableArray *targets = [NSMutableArray array];
            HNPMCoverCollectTargets(cell, targets);
            int t = 0;
            Class platterClsC = NSClassFromString(@"PLPlatterView");
            for (UIView *mat in targets) {
                // 托盘目标(bg 缺席期)不隐藏; 材质目标隐藏
                t += HNPMCoverApplyOnMaterial(mat, a,
                        !(platterClsC && [mat isKindOfClass:platterClsC]));
            }
            if (t > 0 && fabs(cell.alpha - 1.0) > 0.01) cell.alpha = 1.0;
            return t;
        }
        Class platterCls = NSClassFromString(@"PLPlatterView");
        if (!platterCls) return 0;
        int total = 0;
        NSMutableArray *stack = [NSMutableArray arrayWithObject:cell];
        int guard = 0;
        while (stack.count > 0 && guard++ < 120) {
            UIView *v = stack.firstObject;
            [stack removeObjectAtIndex:0];
            if (!v) continue;
            if ([NSStringFromClass([v class]) containsString:@"Remote"]) continue;
            if ([v isKindOfClass:platterCls]) {
                total += HNPMCoverMode() ? HNPMPlatterApplyCover(v, a) : HNPMPlatterApplyBg(v, a);
                if (total > 0 && fabs(cell.alpha - 1.0) > 0.01) cell.alpha = 1.0;
            }
            [stack addObjectsFromArray:v.subviews];
        }
        return total;
    } @catch (NSException *e) {}
    return 0;
}

// v0.0.92: 只读 — 第一张在场登记卡的托盘背景 alpha(无卡/无托盘返回 -1), 供连扫稳定门
static CGFloat HNPMCardPlatterBgAlphaRead(void) {
    if (![NSThread isMainThread]) return -1;
    @try {
        // v0.1.1: 罩层模式按"材质目标"观测(托盘背景 + 卡内效果视图), 托盘缺席也能判漂移
        if (HNPMCoverMode()) {
            for (UIView *cell in [hnpmCardCells copy]) {
                if (![cell isKindOfClass:[UIView class]]) continue;
                if (cell.hidden || HNPMCardHiddenGet(cell) || !cell.window) continue;
                NSMutableArray *targets = [NSMutableArray array];
                HNPMCoverCollectTargets(cell, targets);
                if (targets.count == 0) continue;   // 该卡暂无材质目标 → 看下一张
                // v0.1.2: 检查**所有**目标 — 亮屏重建时系统会新建材质视图, 只查 firstObject
                //          会漏报"正常", 连扫稳定门永不触发(v0.1.1 实测)。
                // v0.1.3: 覆盖判定 = 罩层存在 + alpha 达标(隐藏与否不再判 — bg 被系统
                //          重新露出时仍在罩层之下, 视觉无影响; z 序由每次应用时校正)
                CGFloat a = HNPMBgAlpha();
                CGFloat firstAlpha = -1;
                for (UIView *mat in targets) {
                    UIVisualEffectView *cover = HNPMCoverForView(mat);
                    if (!cover || fabs(cover.alpha - a) > 0.01) {
                        return 1.0;   // 任一目标无罩/alpha 偏 → 满偏差, 触发修正
                    }
                    if (firstAlpha < 0) firstAlpha = cover.alpha;
                }
                return firstAlpha;
            }
            return -1;
        }
        Class platterCls = NSClassFromString(@"PLPlatterView");
        if (!platterCls) return -1;
        for (UIView *cell in [hnpmCardCells copy]) {
            if (![cell isKindOfClass:[UIView class]]) continue;
            if (cell.hidden || HNPMCardHiddenGet(cell) || !cell.window) continue;
            NSMutableArray *stack = [NSMutableArray arrayWithObject:cell];
            int guard = 0;
            while (stack.count > 0 && guard++ < 120) {
                UIView *v = stack.firstObject;
                [stack removeObjectAtIndex:0];
                if (!v) continue;
                if ([NSStringFromClass([v class]) containsString:@"Remote"]) continue;
                if ([v isKindOfClass:platterCls]) {
                    UIView *bg = HNPMPlatterBgView(v, NULL);
                    return bg ? bg.alpha : v.alpha;
                }
                [stack addObjectsFromArray:v.subviews];
            }
        }
    } @catch (NSException *e) {}
    return -1;
}

// v0.0.97: 场景宿主反渐显 v2 — 时序 dump 实锤(v0.0.95/96): 远端场景宿主包装视图(plain UIView,
//          直接子视图含 _UIScenePresentationView)在每次激活/重挂时以 alpha 0→1 渐显约 1s
//          (实拍 model a=0.00 / presentation p=0.54/0.91 / h=0), 渐显期间整个远端
//          内容(歌词行)被压暗 = 用户所见"歌词变暗"。v0.0.96 零命中但 dump 拍到渐显中,
//          说明旧条件(model alpha)有盲区 → 改为 presentation 层触发(动画中值可见):
//          在窗 + 未隐藏 + (model<1 或 presentation<1) → 钳 model=1.0 + removeAllAnimations;
//          并在连扫窗口内每秒输出一次宿主巡检心跳(无论是否命中), 供下次排障定位条件盲区。
static CFAbsoluteTime sHNPMFadeClampLastLog = 0;
static BOOL HNPMClampSceneHostFade(UIView *cell) {
    if (![NSThread isMainThread]) return NO;
    BOOL clamped = NO;
    @try {
        NSMutableArray *stack = [NSMutableArray arrayWithObject:cell];
        int guard = 0;
        while (stack.count > 0 && guard++ < 60) {
            UIView *v = stack.firstObject;
            [stack removeObjectAtIndex:0];
            if (!v || !v.window) continue;
            BOOL hasSceneChild = NO;
            for (UIView *s in v.subviews) {
                if ([NSStringFromClass([s class]) containsString:@"_UIScene"]) { hasSceneChild = YES; break; }
            }
            if (hasSceneChild) {
                CALayer *pl = (CALayer *)v.layer.presentationLayer;
                CGFloat pop = pl ? pl.opacity : v.alpha;
                CGFloat oldA = v.alpha;
                BOOL need = (!v.hidden && (oldA < 0.99 || pop < 0.99));
                if (need) {
                    HNPMSetAlphaNoAnim(v, 1.0);
                    [v.layer removeAllAnimations];
                    clamped = YES;
                }
                CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                if (now - sHNPMFadeClampLastLog > 1.0) {   // 心跳/截断日志限频 1s
                    sHNPMFadeClampLastLog = now;
                    if (need) {
                        HNPMAppendLog([NSString stringWithFormat:@"[透明] 场景宿主渐显截断(a=%.2f p=%.2f→1.0)",
                                       oldA, pop]);
                    } else {
                        HNPMAppendLog([NSString stringWithFormat:@"[透明·宿主巡检] a=%.2f p=%.2f h=%d(未渐显)",
                                       oldA, pop, v.hidden ? 1 : 0]);
                    }
                }
                return clamped;   // 找到宿主包装即停(无论是否钳制)
            }
            [stack addObjectsFromArray:v.subviews];
        }
    } @catch (NSException *e) {}
    return clamped;
}

static void HNPMClampAllCells(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ HNPMClampAllCells(); });
        return;
    }
    @try {
        for (UIView *cell in [hnpmCardCells copy]) {
            if (![cell isKindOfClass:[UIView class]] || !cell.window) continue;
            if (HNPMClampSceneHostFade(cell)) break;
        }
    } @catch (NSException *e) {}
}

// ---- v0.0.90: 亮屏逐帧连扫 ----
// v0.0.89 真机日志实锤: 亮屏瞬间(08:34:00)hook 已秒补, 但 2 秒后(08:34:02)系统又重建卡片
// 并把 alpha 重置 —— 重置点落在"预登记之后、托盘首次布局之前"的缝隙, 事件驱动堵不死。
// 终解: 每次卡片挂载/托盘重置触发一个 CADisplayLink 连扫窗口(3s), 逐帧检查已登记卡的
// 托盘 alpha, 偏差当帧修正(60-120Hz) —— 任何时机的重置最多存活一帧(≈8-16ms), 视觉不可感知。
// 屏幕熄灭时 DisplayLink 自动暂停(零功耗), 亮屏自动恢复。
static CADisplayLink *sHNPMAlphaBurst = nil;
static CFAbsoluteTime sHNPMAlphaBurstEnd = 0;
static BOOL sHNPMAlphaBurstLogged = NO;
static CGFloat sHNPMAlphaBurstLastObs = -1;   // v0.0.92: 稳定门 — 上一帧观测值
static int sHNPMAlphaBurstStable = 0;         // v0.0.92: 稳定门 — 连续相同观测计数

@interface HNPMBurstTarget : NSObject
@end
@implementation HNPMBurstTarget
- (void)onTick:(CADisplayLink *)dl {
    @try {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now > sHNPMAlphaBurstEnd) {
            [dl invalidate];
            if (sHNPMAlphaBurst == dl) sHNPMAlphaBurst = nil;
            return;
        }
        // v0.0.97: 场景宿主反渐显 v2(每帧检查; presentation 层触发 + 心跳日志)
        HNPMClampAllCells();
        // v0.1.8: 连扫帧内节流直扫(0.25s 一次) — 兜住亮屏窗口内系统分批重建的后期批次
        static CFAbsoluteTime sHNPMCoversSweepLast;
        if (now - sHNPMCoversSweepLast > 0.25) {
            sHNPMCoversSweepLast = now;
            HNPMCoversWakeSweep();
        }
        // v0.0.92: 稳定门 — 连续两帧观测到同一静态偏差才写。系统动画/过渡中的瞬时 alpha
        //          一律不追(逐帧写 alpha 会与材质渲染打架 → 远端内容更新被挤掉, 进度条滞后);
        //          静态重置则第二帧即写(≈8-16ms, 视觉无差)。
        CGFloat a = HNPMBgAlpha();
        if (a < 0.99) {
            CGFloat cur = HNPMCardPlatterBgAlphaRead();
            if (cur >= 0) {
                if (sHNPMAlphaBurstLastObs >= 0 && fabs(cur - sHNPMAlphaBurstLastObs) < 0.005) {
                    sHNPMAlphaBurstStable++;
                } else {
                    sHNPMAlphaBurstStable = 0;
                }
                sHNPMAlphaBurstLastObs = cur;
                if (fabs(cur - a) > 0.01 && sHNPMAlphaBurstStable >= 1) {
                    sHNPMAlphaBurstStable = 0;
                    int total = 0;
                    for (UIView *cell in [hnpmCardCells copy]) {
                        if (![cell isKindOfClass:[UIView class]]) continue;
                        @try { total += HNPMInstantPlatterAlpha(cell); } @catch (NSException *e) {}
                    }
                    if (total > 0) {
                        if (!sHNPMAlphaBurstLogged) {
                            sHNPMAlphaBurstLogged = YES;
                            HNPMAppendLog(@"[透明] 连扫修正(稳定偏差, 帧边界写入)");
                        }
                        sHNPMAlphaBurstEnd = CFAbsoluteTimeGetCurrent() + 1.0;   // 又发现重置 → 延长窗口
                    }
                }
            }
        }
    } @catch (NSException *e) {}
}
@end

static HNPMBurstTarget *sHNPMAlphaBurstTarget = nil;

static void HNPMStartAlphaBurst(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ HNPMStartAlphaBurst(); });
        return;
    }
    sHNPMAlphaBurstEnd = CFAbsoluteTimeGetCurrent() + 3.0;
    sHNPMAlphaBurstLogged = NO;
    if (sHNPMAlphaBurst) return;   // 已在跑: 只续窗口
    if (!sHNPMAlphaBurstTarget) return;
    sHNPMAlphaBurstLastObs = -1;   // v0.0.92: 新窗口重置稳定门观测
    sHNPMAlphaBurstStable = 0;
    sHNPMAlphaBurst = [CADisplayLink displayLinkWithTarget:sHNPMAlphaBurstTarget selector:@selector(onTick:)];
    [sHNPMAlphaBurst addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

// v0.1.37: 卡区白巡(只读) — v0.1.36 实测裁决: 钉扎钩子注册成功(宿主类存在)但 24 次
//          亮/灭屏全程 0 次捕获时刻触发, 白源探针也从未见到 CaptureOnly 宿主 → 该宿主
//          不参与本机唤醒首帧; 且关键词探针只认 6 类关键词, 普通类名的白底视图
//          (纯 UIView/ContentView 的 backgroundColor)全部漏网。本巡检改按"几何+颜色"
//          抓白: 亮/灭屏 +0.05/0.2/0.5/1.0s 各一次, 对所有与卡区记忆相交且有效可见
//          (隐祖/透明祖剪枝)的视图 dump 类名/窗口/frame/alpha/背景色(view+layer),
//          白底画手无论叫什么名字都无处遁形。
static NSString *HNPMCGColorDesc(CGColorRef c) {
    if (!c) return @"nil";
    size_t n = CGColorGetNumberOfComponents(c);
    const CGFloat *cs = CGColorGetComponents(c);
    if (n >= 4)
        return [NSString stringWithFormat:@"rgba(%.2f,%.2f,%.2f,%.2f)", cs[0], cs[1], cs[2], cs[3]];
    if (n == 2)
        return [NSString stringWithFormat:@"ga(%.2f,%.2f)", cs[0], cs[1]];
    return [NSString stringWithFormat:@"cmp%zu", n];
}

static void HNPMRegionWhiteProbe(NSString *tag) {
    if (![NSThread isMainThread]) return;
    @try {
        if (CGRectIsEmpty(sHNPMCardRegion33)) {
            HNPMAppendLog([NSString stringWithFormat:@"[卡区白巡@%@] 卡区=空(未登记)", tag]);
            return;
        }
        NSMutableArray *all = [NSMutableArray array];
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (!w || w.hidden || w.alpha < 0.01) continue;
            int guard = 0;
            NSMutableArray *stack = [NSMutableArray arrayWithObject:w];
            while (stack.count > 0 && guard++ < 1200 && all.count < 160) {
                UIView *v = stack.firstObject;
                [stack removeObjectAtIndex:0];
                if (!v) continue;
                if (v != w && (v.hidden || v.alpha < 0.01)) continue;   // 不可见→子树一并剪枝
                if (v.tag == HNPM_COVER_TAG) continue;                  // 自家罩层不算
                CGRect vf = [v convertRect:v.bounds toView:nil];
                CGRect inter = CGRectIntersection(vf, sHNPMCardRegion33);
                if (!CGRectIsNull(inter) && !CGRectIsEmpty(inter)) {
                    NSString *bg = v.backgroundColor ? HNPMCGColorDesc(v.backgroundColor.CGColor) : @"nil";
                    NSString *lbg = v.layer.backgroundColor ? HNPMCGColorDesc(v.layer.backgroundColor) : @"nil";
                    [all addObject:[NSString stringWithFormat:
                        @"%@|win=%@ %.0fx%.0f@%.0f,%.0f a=%.2f bg=%@ lbg=%@",
                        NSStringFromClass([v class]), NSStringFromClass([w class]),
                        vf.size.width, vf.size.height, vf.origin.x, vf.origin.y,
                        v.alpha, bg, lbg]];
                }
                [stack addObjectsFromArray:v.subviews];
            }
        }
        // v0.1.39: 修复 v0.1.38 尺寸解析 bug(尺寸在'@'之前, 之前取到的是坐标→全屏判定从未生效)
        NSMutableArray *rows = [NSMutableArray array];
        for (NSString *r in all) {
            if (rows.count >= 24) break;
            NSUInteger at = [r rangeOfString:@"@"].location;
            if (at == NSNotFound) { [rows addObject:r]; continue; }
            NSString *pre = [r substringToIndex:at];               // "类|win=窗 393x852"
            NSRange sp = [pre rangeOfString:@" " options:NSBackwardsSearch];
            if (sp.location == NSNotFound) { [rows addObject:r]; continue; }
            NSString *sizeTok = [pre substringFromIndex:sp.location + 1];   // "393x852"
            NSArray *wh = [sizeTok componentsSeparatedByString:@"x"];
            if (wh.count != 2) { [rows addObject:r]; continue; }
            double pw = [wh[0] doubleValue], ph = [wh[1] doubleValue];
            BOOL fullscreen = (pw >= 360 && ph >= 790);
            BOOL hasBG = (![r containsString:@" bg=nil lbg=nil"]);
            if (fullscreen && !hasBG) continue;   // 透明全屏容器→丢
            [rows addObject:r];
        }
        HNPMAppendLog([NSString stringWithFormat:@"[卡区白巡@%@] %lu行: %@",
            tag, (unsigned long)rows.count,
            rows.count ? [rows componentsJoinedByString:@" || "] : @"无(卡区无任何可见视图)"]);
    } @catch (NSException *e) {}
}

// v0.1.42: 整卡避让·预隐藏 — 白底根因定论为渲染服务首帧滞后(视图层无解, v0.1.41 裁决:
//          树内无满亮度系统材质、罩层提前就位、白/透明期树逐字节相同)。
//          对策: 在屏幕还黑的按压/灭屏瞬间先把与卡区记忆相交的 NCNotificationListCell
//          alpha=0(首帧渲染时卡区为空 → 无白底可拍), +0.3s 后 0.25s 动画淡入恢复。
//          与 v0.1.24 失败版的本质区别: 那次是亮屏后才藏(白底已上屏), 这次赶在首帧渲染前。
//          互斥规律兜底: 按压时 cell 不在场 → 亮屏首帧也不在场 → 本就无白底。
static NSHashTable *sHNPMPrehiddenCells = nil;

static void HNPMPrehideRestore(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ HNPMPrehideRestore(); });
        return;
    }
    @try {
        if (!sHNPMPrehiddenCells || sHNPMPrehiddenCells.count == 0) return;
        int n = 0;
        for (UIView *v in [sHNPMPrehiddenCells copy]) {
            if (![v isKindOfClass:[UIView class]] || !v.window) continue;
            [UIView animateWithDuration:0.25 animations:^{ v.alpha = 1.0; }];
            n++;
        }
        [sHNPMPrehiddenCells removeAllObjects];
        HNPMAppendLog([NSString stringWithFormat:@"[透明·预隐藏] 淡入恢复 %d 处", n]);
    } @catch (NSException *e) {}
}

static void HNPMPrehideCardCells(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ HNPMPrehideCardCells(); });
        return;
    }
    @try {
        if (!sHNPMPrehiddenCells) sHNPMPrehiddenCells = [NSHashTable weakObjectsHashTable];
        int n = 0;
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (!w || w.hidden) continue;
            int guard = 0;
            NSMutableArray *stack = [NSMutableArray arrayWithObject:w];
            while (stack.count > 0 && guard++ < 600) {
                UIView *v = stack.firstObject;
                [stack removeObjectAtIndex:0];
                if (!v) continue;
                if (v != w && (v.hidden || v.alpha < 0.01)) continue;
                if ([NSStringFromClass([v class]) isEqualToString:@"NCNotificationListCell"]) {
                    if (v.alpha > 0.01 && ![sHNPMPrehiddenCells containsObject:v]) {
                        v.alpha = 0.0;
                        [sHNPMPrehiddenCells addObject:v];
                        n++;
                    }
                    continue;   // cell 整体藏, 不再下钻
                }
                [stack addObjectsFromArray:v.subviews];
            }
        }
        if (n > 0) HNPMAppendLog([NSString stringWithFormat:@"[透明·预隐藏] 已藏卡 %d 处(首帧避让)", n]);
    } @catch (NSException *e) {}
}

// v0.0.91: 亮屏盲区补漏 — v0.0.90 真机毫秒日志实锤: 系统每隔几秒随机重置一次 bg alpha
//          (连扫均当帧修掉), 但若重置恰好发生在"亮屏瞬间、任何触发点出现之前"
//          (旧卡未重建/无布局/无挂载), 连扫窗口不在跑 → 首帧不透明, 等 ~1s 重建才修 →
//          "亮屏第一眼有时透明有时不透明"。
//          补法: 订阅系统亮屏/锁屏 darwin 通知(hasBlankedScreen + lockstate),
//          亮屏瞬间立即开连扫窗口, 与首帧渲染几乎同帧, 视觉无缝。
static void HNPMScreenStateCB(CFNotificationCenterRef center, void *observer,
                              CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    HNPMAppendLog([NSString stringWithFormat:@"[透明] 屏幕状态通知(%@) → 连扫窗口开启",
                   (__bridge NSString *)name]);
    HNPMCapturePersistOnce();   // v0.1.34: 通知即刻压一次(不等 0.5s 节拍)
    // v0.1.42: 整卡避让·预隐藏 — 屏幕还黑的此刻藏卡 cell, +0.3s 淡入恢复(赶在首帧渲染前)
    HNPMPrehideCardCells();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ @try { HNPMPrehideRestore(); } @catch (NSException *e) {} });
    HNPMStartAlphaBurst();
    // v0.1.44: CaptureOnly 宿主完整解剖 — 亮/灭屏 +0.05s 一次, 看清白底画手内部结构
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ @try { HNPMCaptureHostAutopsy(@"0.05"); } @catch (NSException *e) {} });
    // v0.1.43: AOD 捕获层高频侦察+钉扎 — 灭屏捕获/亮屏过渡双窗口, 追 AOD 短命渲染物
    for (NSString *d in @[@"0.02", @"0.05", @"0.1", @"0.2", @"0.4", @"0.8"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                       (int64_t)([d doubleValue] * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try { HNPMCaptureSweep(d); } @catch (NSException *e) {}
        });
    }
    HNPMScheduleDeepDumps();   // v0.0.95: 每次亮/灭屏排程时序化深诊断
    // v0.1.37: 卡区白巡 — 亮/灭屏后 0.05/0.2/0.5/1.0s 各一次(只读, 几何+颜色抓白)
    for (NSString *d in @[@"0.05", @"0.2", @"0.5", @"1.0"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                       (int64_t)([d doubleValue] * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try { HNPMRegionWhiteProbe(d); } @catch (NSException *e) {}
        });
    }
    // v0.1.8: 免登记亮屏直扫 — 立即一次 + 时序化九次, 不等登记/配方(见 HNPMCoversWakeSweep 注释)
    HNPMCoversWakeSweep();
    HNPMScheduleWakeSweeps();
}

// v0.0.95: 时序化深诊断 — v0.0.94 一次性 dump 实锤 dump 瞬间材质容器 h=1、场景宿主 a=0.00 h=1,
//          但单帧无法判断可见化时序。改为亮/灭屏后 0.3/0.8/1.5/2.5s 各 dump 一次(只读),
//          并加 presentation 层 opacity(p=)捕捉动画中的值 — 对齐歌词变暗窗口与重挂时序。
static void HNPMDeepDumpAt(NSString *tag) {
    if (![NSThread isMainThread]) return;
    @try {
        UIView *cell = nil;
        for (UIView *c in [hnpmCardCells copy]) {
            if ([c isKindOfClass:[UIView class]] && c.window) { cell = c; break; }
        }
        if (!cell) {
            HNPMAppendLog([NSString stringWithFormat:@"[透明·深诊断@%@] 无在场登记卡", tag]);
            return;
        }
        NSMutableArray *rows = [NSMutableArray array];
        NSMutableArray *stack = [NSMutableArray arrayWithObject:cell];
        int guard = 0;
        while (stack.count > 0 && guard++ < 200 && rows.count < 40) {
            UIView *v = stack.firstObject;
            [stack removeObjectAtIndex:0];
            if (!v) continue;
            NSString *cls = NSStringFromClass([v class]);
            NSString *extra = @"";
            if ([v isKindOfClass:[UILabel class]]) {
                NSString *t = [(UILabel *)v text] ?: @"";
                if (t.length > 16) t = [t substringWithRange:NSMakeRange(0, 16)];
                extra = [NSString stringWithFormat:@" text=%@", t];
            }
            if ([v isKindOfClass:[UIVisualEffectView class]]) extra = [extra stringByAppendingString:@" <EFX>"];
            // v0.1.40: 标记白底嫌疑犯 — 原生模糊渲染器与材质容器
            if ([cls isEqualToString:@"_UIVisualEffectBackdropView"]) extra = [extra stringByAppendingString:@" <BD>"];
            if ([cls isEqualToString:@"MTMaterialView"]) extra = [extra stringByAppendingString:@" <MT>"];
            if ([cls isEqualToString:@"PLPlatterView"]) extra = [extra stringByAppendingString:@" <PL>"];
            // v0.1.41: 父链消歧 — BD 到底挂在谁下面(我们罩层子树内=无害 / 系统内容层=白底真身)
            NSString *sup = v.superview ? NSStringFromClass([v.superview class]) : @"(nil)";
            if (sup.length > 24) sup = [sup substringFromIndex:sup.length - 24];
            if (v.tag == HNPM_COVER_TAG) extra = [extra stringByAppendingString:@" <COVER>"];
            extra = [extra stringByAppendingFormat:@" sup=%@", sup];
            CALayer *pl = (CALayer *)v.layer.presentationLayer;
            CGFloat pop = pl ? pl.opacity : -1.0;
            [rows addObject:[NSString stringWithFormat:@"%@ a=%.2f p=%.2f h=%d%@",
                             cls, v.alpha, pop, v.hidden ? 1 : 0, extra]];
            [stack addObjectsFromArray:v.subviews];
        }
        HNPMAppendLog([NSString stringWithFormat:@"[透明·深诊断@%@] %lu视图: %@",
                       tag, (unsigned long)rows.count, [rows componentsJoinedByString:@" || "]]);
    } @catch (NSException *e) {}
}

static void HNPMScheduleDeepDumps(void) {
    // v0.1.40: 提前到 +0.01/+0.05/+0.15 — 抓亮屏首帧材质满亮度渲染的时序(v0.1.39 裁决)
    for (NSString *d in @[@"0.01", @"0.05", @"0.15", @"0.3", @"0.8", @"1.5", @"2.5"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)([d doubleValue] * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try {
                HNPMClampAllCells();   // v0.0.97: 连扫窗口外的钳制兜底
                HNPMDeepDumpAt(d);
            } @catch (NSException *e) {}
        });
    }
}

// v0.0.93: 空闲巡逻 — 连扫窗口只覆盖事件后 3s; 若系统在"无任何布局/挂载事件"的空闲期
//          静默重置 alpha(锁屏静置时布局 pass 极少), 侦测 hook 不会触发 → 卡片不透明
//          直到下一个事件(可能数秒)。补法: 0.5s 一次**只读**巡逻(有在场登记卡才继续),
//          发现漂移只开连扫窗口(修正仍走稳定门+帧边界, 零对抗); 无卡自动停(解锁/停播)。
static void HNPMIdleAlphaCheck(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ HNPMIdleAlphaCheck(); });
        return;
    }
    @try {
        CGFloat cur = HNPMCardPlatterBgAlphaRead();
        if (cur >= 0) {   // 有在场登记卡才巡逻
            CGFloat a = HNPMBgAlpha();
            if (a < 0.99 && fabs(cur - a) > 0.01) {
                HNPMStartAlphaBurst();   // 只开窗不写: 修正走连扫稳定门
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ @try { HNPMIdleAlphaCheck(); } @catch (NSException *e) {} });
        }
        // 无卡 → 不再排下一次(解锁/停播自动停)
    } @catch (NSException *e) {}
}

// 把登记卡的背景压到目标 alpha。
// v0.0.72: 真机实锤卡内子树没有 UIVisualEffectView(白底不在卡里)。
// v0.0.74: 头文件实锤(iOS17 运行时头, CoverSheet/UserNotificationsUIKit/PlatterKit) —
//          NCNotificationListSupplementaryHostingView 持有 PLPlatterView *_platterView:
//          卡片白底就是这个"托盘"板(PlatterKit/MTMaterialView 渲染, 不是 UIVisualEffectView
//          → v0.0.71/72 扫描必然扑空), 且 hostedView(内容)与托盘是兄弟层。
//          → 新 P 路: 卡内子树扫 PLPlatterView, 只压托盘 alpha → 背景变透明, 文字保持不透明。
//          托盘由 _configurePlatterViewIfNecessary 惰性创建, 可能晚于首次登记 → 未命中限时重试(1/3/7s)。
//          全部落空(背景远端自绘的第三方卡) → 维持 v0.0.73 整卡淡化兜底。
static void HNPMApplyCardBackgroundAlpha(UIView *cell, int kind) {
    @try {
        CGFloat a = HNPMBgAlpha();
        if (a >= 0.99) {
            if (HNPMCoverMode()) HNPMCoverRestoreAll(cell);   // v0.1.0: 关闭时露出原生材质
            return;   // 1.0 = 功能关闭
        }
        NSMutableSet *touched = [NSMutableSet set];
        // v0.1.1: 罩层模式专用分支 — 目标泛化(托盘背景 + 卡内效果视图), 全程零系统材质写入;
        //          亮屏重建序列里托盘惰性创建晚 ~1s, 卡内效果视图先出现 → 必须也能盖住它
        //          (v0.1.0 用户实测: 亮屏后原生白底 ~1s 才变透)。
        if (HNPMCoverMode()) {
            NSMutableArray *targets = [NSMutableArray array];
            HNPMCoverCollectTargets(cell, targets);
            if (targets.count > 0) {
                Class platterClsC = NSClassFromString(@"PLPlatterView");
                for (UIView *mat in targets) {
                    HNPMCoverApplyOnMaterial(mat, a,
                            !(platterClsC && [mat isKindOfClass:platterClsC]));
                }
                HNPMAlphaRetrySet(cell, 0);
                if (fabs(cell.alpha - 1.0) > 0.01) cell.alpha = 1.0;
                HNPMAppendLog([NSString stringWithFormat:@"[透明] 罩层应用 %lu 目标(材质已隐藏, 零系统写入)",
                               (unsigned long)targets.count]);
                return;
            }
            // 无目标(托盘/效果视图未创建) → 不写系统材质, 快速重试等创建
            NSInteger retried = HNPMAlphaRetryGet(cell);
            if (retried < 3) {
                HNPMAlphaRetrySet(cell, retried + 1);
                CGFloat delay = (retried == 0) ? 0.5 : (retried == 1 ? 1.0 : 2.0);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    @try { HNPMApplyCardBackgroundAlpha(cell, kind); } @catch (NSException *e) {}
                });
            }
            HNPMAppendLog(@"[透明·罩层] 暂无材质目标, 等待系统创建(零系统写入)");
            return;
        }
        // P. v0.0.74: 托盘扫(不深入远程内容子树); v0.0.75 只压其背景子层
        int pHits = 0;
        NSString *pVia = @"";
        Class platterCls = NSClassFromString(@"PLPlatterView");
        if (platterCls) {
            @try {
                NSMutableArray *stack = [NSMutableArray arrayWithObject:cell];
                int guard = 0;
                while (stack.count > 0 && guard++ < 200) {
                    UIView *v = stack.firstObject;
                    [stack removeObjectAtIndex:0];
                    if (!v) continue;
                    NSString *cls = NSStringFromClass([v class]);
                    if ([cls containsString:@"Remote"]) continue;
                    if ([v isKindOfClass:platterCls]) {
                        if (HNPMCoverMode()) {
                            // v0.1.0: 罩层模式 — 系统材质保持原生(α=1.0/recipe 不动),
                            //          我们隐藏它并插入自己的 blur 罩层; 系统随便重配置
                            //          它自己的材质, 诱因链(写入→重建→歌词暗)不再触发。
                            pHits += HNPMPlatterApplyCover(v, a);
                            pVia = @"罩层";
                            UIView *bgc = HNPMPlatterBgView(v, NULL);
                            if (bgc) [touched addObject:bgc];
                        } else {
                        // v0.0.75: 只压托盘的"背景子层" — 真机实测(v0.0.74)压整个托盘时内容
                        //          (customContentView 里的 hostedView)被连带淡化 = 幽灵卡复现。
                        //          头文件分层: backgroundView(白底材质) / customContentView(内容)。
                        // v0.0.88: 背景子层提取/重申下沉为共用函数(亮屏 hook 同源, 保证行为一致)
                        NSString *via = @"";
                        UIView *bg = HNPMPlatterBgView(v, &via);
                        if (bg) {
                            if (fabs(bg.alpha - a) > 0.01) bg.alpha = a;
                            [touched addObject:bg];
                            pHits++; pVia = via;
                            HNPMPlatterDiagDump(v, bg, via);
                        } else {
                            if (fabs(v.alpha - a) > 0.01) v.alpha = a;
                            [touched addObject:v];
                            pHits++; pVia = @"整托盘";
                        }
                        }
                        // v0.0.99: 官方配方覆盖实验(独立于 alpha; 用户以肉眼判断配方观感)
                        //          v0.1.0: 罩层模式下跳过 — 系统材质完全不动
                        if (!HNPMCoverMode()) @try {
                            NSInteger ro = HNPMRecipeOverride();
                            if (ro >= 0) {
                                long long cur = [(PLPlatterView *)v materialRecipe];
                                if (cur != (long long)ro) {
                                    [(PLPlatterView *)v setMaterialRecipe:(long long)ro];
                                    HNPMAppendLog([NSString stringWithFormat:@"[透明] 配方覆盖 %lld→%ld", cur, (long)ro]);
                                }
                            }
                        } @catch (NSException *e) {}
                    }
                    [stack addObjectsFromArray:v.subviews];
                }
            } @catch (NSException *e) {}
        }
        if (pHits > 0) {
            HNPMAlphaRetrySet(cell, 0);                            // cell 复用时重置重试计数
            if (fabs(cell.alpha - 1.0) > 0.01) cell.alpha = 1.0;   // 托盘生效 → 撤销整卡淡化兜底
            HNPMAppendLog([NSString stringWithFormat:@"[透明] 类别2 托盘背景层%d个(%@) alpha→%.2f (文字不受影响)", pHits, pVia, a]);
            return;
        }
        // A. 卡内扫(不深入远程内容子树)
        int inHits = 0;
        @try {
            NSMutableArray *stack = [NSMutableArray arrayWithObject:cell];
            int guard = 0;
            while (stack.count > 0 && guard++ < 200) {
                UIView *v = stack.firstObject;
                [stack removeObjectAtIndex:0];
                if (!v) continue;
                NSString *cls = NSStringFromClass([v class]);
                if ([cls containsString:@"Remote"]) continue;
                if ([v isKindOfClass:[UIVisualEffectView class]]) {
                    if (fabs(v.alpha - a) > 0.01) v.alpha = a;
                    [touched addObject:v];
                    inHits++;
                }
                [stack addObjectsFromArray:v.subviews];
            }
        } @catch (NSException *e) {}
        if (inHits > 0) {
            HNPMAppendLog([NSString stringWithFormat:@"[透明] 类别2 卡内材质层%d个 alpha→%.2f", inHits, a]);
            return;
        }
        // B. 卡外: 沿上层容器找与卡重叠的兄弟视图, 扫其子树材质层
        int outHits = 0;
        UIView *level = cell.superview;
        int depth = 0;
        @try {
            while (level && depth < 4) {
                for (UIView *sib in [level.subviews copy]) {
                    if (!sib || sib == cell || [sib isDescendantOfView:cell] || [cell isDescendantOfView:sib]) continue;
                    if ([touched containsObject:sib]) continue;
                    CGRect sr = [sib convertRect:sib.bounds toView:nil];
                    CGRect cr = [cell convertRect:cell.bounds toView:nil];
                    if (sr.size.height < 30.0 || sr.size.width < 100.0 || !CGRectIntersectsRect(sr, cr)) continue;
                    NSMutableArray *stack = [NSMutableArray arrayWithObject:sib];
                    int guard = 0;
                    while (stack.count > 0 && guard++ < 150) {
                        UIView *v = stack.firstObject;
                        [stack removeObjectAtIndex:0];
                        if (!v) continue;
                        NSString *cls = NSStringFromClass([v class]);
                        if ([cls containsString:@"Remote"]) continue;
                        if ([v isKindOfClass:[UIVisualEffectView class]] && ![touched containsObject:v]) {
                            if (fabs(v.alpha - a) > 0.01) v.alpha = a;
                            [touched addObject:v];
                            outHits++;
                        }
                        [stack addObjectsFromArray:v.subviews];
                    }
                }
                level = level.superview;
                depth++;
            }
        } @catch (NSException *e) {}
        if (outHits > 0) {
            HNPMAppendLog([NSString stringWithFormat:@"[透明] 类别2 卡外托盘材质层%d个 alpha→%.2f", outHits, a]);
            return;
        }
        // C. 全找不到 → 白底是远端内容自绘的(宿主进程渲染), 本地没有任何可压的背景层。
        //    v0.0.73: 兜底 → 整卡淡化(文字/图片也会一并半透明, 深浅由配置值权衡)。
        //    v0.0.74: 先限时重试 P 路托盘(惰性创建可能晚于首次登记, 1s/3s/7s 各一次),
        //             重试期间整卡淡化已生效, 托盘一旦命中 P 路会自动撤销淡化。
        NSInteger retried = HNPMAlphaRetryGet(cell);
        if (retried < 3) {
            HNPMAlphaRetrySet(cell, retried + 1);
            CGFloat delay = (retried == 0) ? 1.0 : (retried == 1 ? 3.0 : 7.0);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                @try { HNPMApplyCardBackgroundAlpha(cell, kind); } @catch (NSException *e) {}
            });
        }
        if (fabs(cell.alpha - a) > 0.01) cell.alpha = a;
        HNPMAppendLog([NSString stringWithFormat:@"[透明] 类别2 无本地托盘/材质层 → 整卡淡化兜底 alpha=%.2f (文字一并半透明)", a]);
    } @catch (NSException *e) {}
}

// v0.0.67: 实时活动卡被藏时的岛侧侦察 — 把 Aperture 窗口里每个元素内容视图的
// 归属标识/类别/frame dump 进日志。
// 背景: 岛侧"其他元素"(kind2)是保护名单(通知/实时活动/待机小图标混在一起, v0.0.5x 时代
// 碰过 → 状态栏空白)。要"只藏被滑卡对应的岛元素"必须先拿到实时活动的岛元素标识长什么样;
// 用户左滑一次外卖卡 → 日志里就有全量样本, 下一版据此建精确匹配器(只藏它, 不碰锁图标等)。
static void HNPMIslandReconLog(NSString *reason) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ HNPMIslandReconLog(reason); });
        return;
    }
    @try {
        int found = 0;
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
                found++;
                CGRect wf = [v convertRect:v.bounds toView:nil];
                NSString *eids = (eid.length > 72)
                    ? [NSString stringWithFormat:@"%@…", [eid substringToIndex:72]]
                    : (eid.length > 0 ? eid : @"(nil)");
                HNPMAppendLog([NSString stringWithFormat:@"[岛侦察] %@ 类别%d eid=%@ frame=%@",
                               reason, kind, eids, NSStringFromCGRect(wf)]);
            }
        }
        if (found == 0) {
            HNPMAppendLog([NSString stringWithFormat:@"[岛侦察] %@ 未见元素内容视图(岛未呈现或共存降级)", reason]);
        }
    } @catch (NSException *e) {}
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
    // v0.0.65 共存: 模型级抑制在"全停"模式(noisland)下不执行; 检出 NativeIsland 时保留(最安全通道)
    if (HNPMIslandMode() < 1) return;
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

// ---- v0.0.69: 实时活动岛元素联动(模型级) ----
// 真机样本(2026-10-21 岛侦察): 岛上实时活动元素 eid 形如 activity:<UUID>:<addr>。
// 链路: 左滑实时活动卡 → 从锁屏单元格 ivar 树探 UUID → 抑制岛上含同 UUID 的 activity: 元素
// (走苹果 shouldSuppressElement* 同款模型级通道, 与 NativeIsland 共存安全; 视图级不碰)。

static BOOL HNPMIsUUIDString(NSString *s) {
    if (s.length != 36) return NO;
    for (NSUInteger i = 0; i < 36; i++) {
        unichar c = [s characterAtIndex:i];
        if (i == 8 || i == 13 || i == 18 || i == 23) { if (c != '-') return NO; }
        else if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))) return NO;
    }
    return YES;
}

// 沿单元格 ivar 树(对象型, 最多扫40个对象, 每类2级父类)收集 UUID 形/activity: 形字符串。
// 注意: 结果不缓存 — NCNotificationListCell 对象会被系统复用, 缓存会张冠李戴。
static NSArray *HNPMProbeActivityUUIDs(UIView *cell, BOOL logFound) {
    NSMutableArray *out = [NSMutableArray array];
    if (!cell) return out;
    @try {
        NSMutableArray *work = [NSMutableArray arrayWithObject:cell];
        int scanned = 0;
        while (work.count > 0 && scanned < 40) {
            id obj = work.firstObject;
            [work removeObjectAtIndex:0];
            if (!obj) continue;
            scanned++;
            Class c = [obj class];
            int cd = 0;
            while (c && cd < 2) {
                unsigned int n = 0;
                Ivar *ivs = class_copyIvarList(c, &n);
                for (unsigned int i = 0; i < n && i < 64; i++) {
                    const char *ty = ivar_getTypeEncoding(ivs[i]);
                    if (!ty || ty[0] != '@') continue;
                    id v = nil;
                    @try { v = object_getIvar(obj, ivs[i]); } @catch (NSException *e) { continue; }
                    if (!v || v == obj || [work containsObject:v]) continue;
                    if ([v isKindOfClass:[NSString class]]) {
                        NSString *sv = v;
                        BOOL hit = HNPMIsUUIDString(sv)
                            || (sv.length >= 10 && sv.length <= 120 && [[sv lowercaseString] containsString:@"activity:"]);
                        if (hit && ![out containsObject:sv]) {
                            [out addObject:sv];
                            if (logFound) {
                                NSString *show = (sv.length > 72) ? [NSString stringWithFormat:@"%@…", [sv substringToIndex:72]] : sv;
                                HNPMAppendLog([NSString stringWithFormat:@"[身份] 命中 ivar=%s 值=%@",
                                               ivar_getName(ivs[i]), show]);
                            }
                        }
                    } else if ([v isKindOfClass:[NSObject class]]) {
                        [work addObject:v];   // 嵌套模型对象再挖(总数封顶40)
                    }
                }
                if (ivs) free(ivs);
                c = [c superclass];
                cd++;
            }
        }
    } @catch (NSException *e) {}
    return out;
}

// 岛 activity: 元素匹配: UUID 精确(被滑卡身份串出现在 eid 中)或兜底全部
static BOOL HNPMIsActivityElement(id el) {
    @try {
        if (!el || !hnpmActivitySuppress) return NO;
        SEL gi = NSSelectorFromString(@"elementIdentifier");
        if (![el respondsToSelector:gi]) return NO;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id v = [el performSelector:gi];
#pragma clang diagnostic pop
        if (![v isKindOfClass:[NSString class]]) return NO;
        NSString *eid = v;
        if (![eid hasPrefix:@"activity:"]) return NO;
        if (hnpmActivityUUIDs.count == 0) return YES;   // 兜底: 探不到身份时匹配全部 activity: 元素
        for (NSString *k in hnpmActivityUUIDs) {
            if (k.length > 0 && [eid containsString:k]) return YES;
        }
        return NO;
    } @catch (NSException *e) { return NO; }
}

// 模型级抑制(同 NowPlaying 通道): setRequiresSuppressionFromSystemAperture + 重评估
static void HNPMSetActivitySuppression(BOOL suppress, NSString *tag) {
    if (HNPMIslandMode() < 1) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            NSMutableArray *targets = [NSMutableArray array];
            if (hnpmActivityTable) {
                NSArray *snap = nil;
                @synchronized(hnpmActivityTable) { snap = [[hnpmActivityTable allObjects] copy]; }
                for (id e in snap) {
                    if (e && HNPMIsActivityElement(e) && ![targets containsObject:e]) [targets addObject:e];
                }
            }
            id ctrl = HNPMIslandController();
            if (ctrl) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                SEL fe = NSSelectorFromString(@"_currentFirstElement");
                if ([ctrl respondsToSelector:fe]) {
                    id el = [ctrl performSelector:fe];
                    if (el && HNPMIsActivityElement(el) && ![targets containsObject:el]) [targets addObject:el];
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
            int ree = 0;
            if (ctrl) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                SEL re = NSSelectorFromString(@"_reevaluateSystemApertureCompleteSuppression");
                if ([ctrl respondsToSelector:re]) { [ctrl performSelector:re]; ree = 1; }
#pragma clang diagnostic pop
            }
            HNPMAppendLog([NSString stringWithFormat:@"[抑制活%@] 目标%d 置%d 重评估%d 匹配%@",
                           tag, (int)targets.count, set, ree,
                           hnpmActivityUUIDs.count > 0 ? @"精确(UUID)" : @"全部(activity:)"]);
        } @catch (NSException *e) {
            HNPMAppendLog([NSString stringWithFormat:@"[抑制活%@] 异常: %@", tag, e.reason]);
        }
    });
}

static void HNPMClearActivitySuppression(NSString *tag) {
    if (!hnpmActivitySuppress) return;
    hnpmActivitySuppress = NO;
    HNPMSetActivitySuppression(NO, tag);
    hnpmActivityUUIDs = nil;
}

// 在场卡重新登记时, 若其身份与被抑制的实时活动匹配 → 解除(活动重新呈现了)
static void HNPMClearActivitySuppressionIfMatch(UIView *cell, int kind) {
    if (!hnpmActivitySuppress) return;
    BOOL hit = NO;
    if (hnpmActivityUUIDs.count == 0) {
        hit = (kind == 2);   // 兜底模式: 任一实时活动卡重新在场即解除
    } else {
        NSArray *u = HNPMProbeActivityUUIDs(cell, NO);
        for (NSString *k in hnpmActivityUUIDs) {
            for (NSString *p in u) {
                if (p.length > 0 && ([p containsString:k] || [k containsString:p])) { hit = YES; break; }
            }
            if (hit) break;
        }
    }
    if (hit) HNPMClearActivitySuppression(@"活动卡重新在场");
}

// v0.0.47: "媒体元素全家桶"隐藏 —— 内容视图 + 其祖先 + 尺寸带内与媒体 frame 重叠的外壳
// v0.0.53: 其他元素(通知/实时活动/待机小图标)的内容视图及其祖先记入"共享"集合, 绝不隐藏
//   (修复: 隐藏期来通知, 媒体视图被重挂进共享容器 → 连带藏掉状态栏/待机链 → 状态栏全空)
// 恢复时同一套判定反向点亮; 只对内容视图做原位重新挂载(抗黑壳)
static void HNPMSetIslandContentHidden(BOOL hide, NSString *tag) {
    // v0.0.65 共存: 视图级直改(hidden/重挂载/窗口抖动)在"全停"或"检出NativeIsland"模式下停用。
    // 轮询每 0.5~2s 调一次本函数 → 停用原因只记一行, 防日志刷屏。
    if (HNPMIslandMode() < 2) {
        static BOOL loggedSkip = NO;
        if (!loggedSkip) {
            loggedSkip = YES;
            HNPMAppendLog([NSString stringWithFormat:@"[岛内] 视图级直改已停用(岛侧模式: %@)",
                           HNPMIslandModeName(HNPMIslandMode())]);
        }
        return;
    }
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

// 隐藏被左滑的那张卡(音乐卡或实时活动卡, 各卡状态独立)
static void HNPMHideCard(UIView *cell) {
    if (!cell || !cell.window) return;
    BOOL isMusic = (HNPMCellClassGet(cell) == 1);
    if (isMusic) hnpmHiddenCard = cell;   // 暂停恢复锚: 只有音乐卡走"播放恢复显示"通道
    HNPMCardHiddenSet(cell, YES);
    HNPMCardShiftSet(cell, 0.0);          // 藏掉的卡位移归零(动画完成后 transform 复位)
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
                    if (HNPMCardHiddenGet(cell)) {
                        cell.hidden = YES;
                        cell.transform = CGAffineTransformIdentity;
                        cell.alpha = 1.0;
                    }
                } @catch (NSException *e) {}
            }];
        } @catch (NSException *e) {}
    });
    if (!isMusic) HNPMAppendLog([NSString stringWithFormat:@"[卡片] 左滑隐藏(类别%d, 通道待MR裁决)", HNPMCellClassGet(cell)]);
}

static void HNPMShowCards(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            // 内容视图放回来(隐藏期新建的卡片, 内容视图被单独藏过; 不放回来就是白片)
            for (UIView *content in hnpmCardContents) {
                if (content.window && content.isHidden) content.hidden = NO;
            }
            // 找要恢复的卡片: 优先被左滑那张(v0.0.68: 不再看身份 — 本地特征分类在远程渲染下
            // 失灵, 音乐卡也会被判类别2, 身份闸门会把恢复拦死); 系统重建过就找最底部的隐藏媒体卡
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
            HNPMCardHiddenSet(cell, NO);   // 暂停恢复通道: 清掉左滑隐藏标志(否则下次登记会被重新藏)
            HNPMCardShiftSet(cell, 0.0);
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
            // v0.0.69: 恢复锚若带实时活动身份(误入音乐通道的实时活动卡) → 解除其岛抑制
            if (hnpmActivitySuppress) {
                NSArray *u = HNPMProbeActivityUUIDs(cell, NO);
                BOOL hit = (hnpmActivityUUIDs.count == 0)
                    ? (HNPMCellClassGet(cell) == 2)
                    : NO;
                if (!hit) {
                    for (NSString *k in hnpmActivityUUIDs) {
                        for (NSString *p in u) {
                            if (p.length > 0 && ([p containsString:k] || [k containsString:p])) { hit = YES; break; }
                        }
                        if (hit) break;
                    }
                }
                if (hit) HNPMClearActivitySuppression(@"恢复通道");
            }
            // 恢复动画结束后再补位(下方实时活动藏过 → 音乐卡落到低位)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                HNPMApplyCardLayout(YES);
                // v0.0.74: 恢复显示后补一次背景压暗(托盘 alpha 不随显示动画走, 但保险起见重申)
                @try { HNPMApplyCardBackgroundAlpha(cell, HNPMCellClassGet(cell)); } @catch (NSException *e) {}
            });
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

static void HNPMSetHidden(BOOL hide, NSString *reason, BOOL linkIsland) {
    if (hide == hnpmHidden) return;
    hnpmHidden = hide;
    hnpmIslandLinked = (hide && linkIsland);
    hnpmBaseline = NO;
    hnpmPauseStreak = 0;
    if (hide) {
        HNPMRegisterMediaListen(YES);  // v0.0.63: 隐藏期短暂挂媒体通知链(通知→限流即时查询)
        HNPMBumpFastPhase();  // 刚隐藏的 10s 内用快节奏盯紧过渡期
        // v0.0.68: 岛联动可关 — 实时活动卡/多卡歧义场景不碰岛(卡片已由 handlePan 单独隐藏)
        if (linkIsland) {
            HNPMSetIslandContentHidden(YES, @"隐藏");
            // v0.0.51: 模型级抑制(置属性+触发重评估, 应即时生效; +2s 重申兜底)
            HNPMSetElementSuppression(YES, @"·隐");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                @try {
                    if (hnpmHidden && linkIsland) HNPMSetElementSuppression(YES, @"·隐2");
                } @catch (NSException *e) {}
            });
        }
    } else {
        HNPMRegisterMediaListen(NO);  // v0.0.63: 恢复立即注销摘链
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
                        // 稳态: 推迟下一跳到 2.0s(v0.0.59: 1.0→1.5; v0.0.64: 1.5→2.0 — MR通知监听已复活,
                        // 播放状态变化由通知驱动即时查询, 轮询只是兜底, 放宽到2.0s; 机制仍是 NSTimer)
                        if (!hnpmSteadyLogged) {
                            HNPMAppendLog(@"[轮询] 转入稳态 2.0s");
                            hnpmSteadyLogged = YES;
                        }
                        [t setFireDate:[NSDate dateWithTimeIntervalSinceNow:2.0]];
                    }
                    // 快相: 不推迟, 保持 0.5s 原节奏
                    if (hnpmIslandLinked) HNPMSetIslandContentHidden(YES, @"轮询");   // v0.0.68: 岛联动关时轮询不碰岛
                    HNPMQueryNowPlayingOnce();
                } @catch (NSException *e) {}
            }];
            [[NSRunLoop mainRunLoop] addTimer:hnpmPollTimer forMode:NSRunLoopCommonModes];
        } @catch (NSException *e) {}
    });
}

// v0.0.87: 设置面板改动回调(PostNotification → darwin notify)
//          清透明度缓存; "锁屏左滑隐藏"被关掉时若处于隐藏态 → 立即恢复。
static void HNPMPrefsChangedCB(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    CFPreferencesAppSynchronize(CFSTR("com.aha.hidenowplaying"));
    HNPMBgAlphaInvalidate();
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (!HNPMPrefSwipeHide() && hnpmHidden) {
                HNPMSetHidden(NO, @"设置开关恢复", YES);
                HNPMAppendLog(@"[设置] 锁屏左滑隐藏=关 → 恢复显示");
            }
        } @catch (NSException *e) {}
    });
}

// v0.0.68: 左滑后的身份裁决 — 本地特征分类在真机失灵(CSActivityItemContentView 内容是
// 远程渲染的, 本地视图树里没有 UILabel/UIButton, 特征评分只剩高度一项, 音乐卡也被判类别2),
// 只能借 MediaRemote 会话状态: 有活跃会话(播放或暂停) → 按音乐卡走恢复通道; 无会话 → 纯实时活动。
// 视图级隐藏不等裁决, 立即执行(动画不卡顿); 岛联动仅在"单卡"场景全开(多卡时无法排除滑的是实时活动)。
static void HNPMSwipeSettle(UIView *cell, int kind) {
    if (!hnpmGetInfo) {
        HNPMAppendLog(@"[裁决] MR符号缺失 → 仅视图级隐藏(无岛联动/无暂停恢复)");
        return;
    }
    hnpmGetInfo(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(CFDictionaryRef info) {
        @try {
            BOOL hasInfo = (info != NULL && CFDictionaryGetCount(info) > 0);
            double rate = 0;
            if (hasInfo) {
                CFNumberRef r = CFDictionaryGetValue(info, CFSTR("kMRMediaRemoteNowPlayingInfoPlaybackRate"));
                if (r) CFNumberGetValue(r, kCFNumberDoubleType, &rate);
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    if (!cell.window) {
                        HNPMAppendLog(@"[裁决] 返回时卡片已不在场 → 忽略");
                        return;
                    }
                    // v0.0.69: 身份探针(两种通道都探) — UUID 精确匹配岛上 activity: 元素
                    NSArray *uuids = HNPMProbeActivityUUIDs(cell, YES);
                    if (!hasInfo) {
                        HNPMAppendLog(@"[裁决] MR无媒体会话 → 纯实时活动卡(不进恢复通道/不联动NowPlaying岛)");
                        // 岛联动: 探到UUID→精确匹配; 探不到→兜底全部activity:元素
                        hnpmActivitySuppress = YES;
                        hnpmActivityUUIDs = uuids;
                        HNPMSetActivitySuppression(YES, @"·隐");
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                                       dispatch_get_main_queue(), ^{
                            @try { if (hnpmActivitySuppress) HNPMSetActivitySuppression(YES, @"·隐2"); } @catch (NSException *e) {}
                        });
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                                       dispatch_get_main_queue(), ^{
                            @try { if (hnpmActivitySuppress) HNPMSetActivitySuppression(YES, @"·隐3"); } @catch (NSException *e) {}
                        });
                        return;
                    }
                    BOOL single = (hnpmCardCells.count <= 1);
                    HNPMAppendLog([NSString stringWithFormat:@"[裁决] MR会话活跃(rate=%.2f, 在场卡片%lu张, 单卡=%d) → 按音乐卡处理(岛联动=%d)",
                                   rate, (unsigned long)hnpmCardCells.count, single ? 1 : 0, (single || kind == 1) ? 1 : 0]);
                    hnpmHiddenCard = cell;   // 恢复锚: 被滑的那张(身份分类失灵, 不再区分)
                    if (uuids.count > 0) {
                        // v0.0.69: 被滑卡带实时活动身份 → 精确抑制其岛上元素(即便误入音乐通道)
                        hnpmActivitySuppress = YES;
                        hnpmActivityUUIDs = uuids;
                        HNPMSetActivitySuppression(YES, @"·精");
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                                       dispatch_get_main_queue(), ^{
                            @try { if (hnpmActivitySuppress) HNPMSetActivitySuppression(YES, @"·精2"); } @catch (NSException *e) {}
                        });
                    }
                    if (!hnpmHidden) {
                        HNPMSetHidden(YES, @"锁屏播放卡片左滑", single || kind == 1);
                        HNPMStartRestorePolling();
                    }
                } @catch (NSException *e) {}
            });
        } @catch (NSException *e) {}
    });
}

#pragma mark - 左滑手势 target + 代理

@interface HNPMPanTarget : NSObject <UIGestureRecognizerDelegate>
@end

@implementation HNPMPanTarget

- (void)handlePan:(UIPanGestureRecognizer *)gr {
    @try {
        // v0.0.67: 音乐卡与其他实时活动卡都可左滑(各卡独立状态, 互不影响)
        Class cellClass = NSClassFromString(@"NCNotificationListCell");
        UIView *p = gr.view;
        while (p && ![p isKindOfClass:cellClass]) p = p.superview;
        if (!p) return;
        // v0.0.87: 功能总闸 — 设置里"锁屏左滑隐藏"=关 → 手势完全失效(岛也不动)
        if (!HNPMPrefSwipeHide()) {
            if (gr.state == UIGestureRecognizerStateBegan) {
                HNPMAppendLog(@"[设置] 锁屏左滑隐藏=关 → 手势忽略");
            }
            return;
        }
        int kind = HNPMCellClassGet(p);
        BOOL accept = (kind == 1 || kind == 2) ? YES : HNPMIsBottomMostMediaCell(p);   // 未定性退回位置启发式
        // v0.0.54: 只在手势开始/判定翻转时记日志(原每个触摸事件都记, 一滑刷十几行)
        static BOOL hnpmLastPanAccept = NO;
        if (gr.state == UIGestureRecognizerStateBegan || accept != hnpmLastPanAccept) {
            hnpmLastPanAccept = accept;
            @try {
                HNPMAppendLog([NSString stringWithFormat:@"[判定] 类别%d → %@",
                               kind, accept ? @"接受(左滑可藏)" : @"拒绝"]);
            } @catch (NSException *e) {}
        }
        if (!accept) return;
        CGPoint t = [gr translationInView:gr.view];
        CGPoint v = [gr velocityInView:gr.view];
        // v0.0.69: 一次手势只触发一次(Changed/Ended多次过阈值曾致一秒内N次裁决+侦察)
        static BOOL hnpmPanFired = NO;
        if (gr.state == UIGestureRecognizerStateBegan) hnpmPanFired = NO;
        if (gr.state == UIGestureRecognizerStateChanged) {
            if (t.x < -60 && fabs(t.x) > fabs(t.y) * 1.5 && !hnpmPanFired) {
                hnpmPanFired = YES;
                HNPMHideCard(p);
                HNPMApplyCardLayout(YES);   // 下方藏卡 → 上方可见卡下移补位
                HNPMLayoutRetryBurst();
                if (kind == 2) HNPMIslandReconLog(@"实时活动卡藏");   // 岛侧样本采集(为下一版精确联动做准备)
                HNPMSwipeSettle(p, kind);   // v0.0.68: MR异步裁决音乐/实时活动通道
            }
        } else if (gr.state == UIGestureRecognizerStateEnded) {
            if (t.x < -55 && fabs(t.x) > fabs(t.y) * 1.2 && v.x < -300 && !hnpmPanFired) {
                hnpmPanFired = YES;
                HNPMHideCard(p);
                HNPMApplyCardLayout(YES);
                HNPMLayoutRetryBurst();
                if (kind == 2) HNPMIslandReconLog(@"实时活动卡藏");
                HNPMSwipeSettle(p, kind);
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
        // v0.0.89: 预登记 — 尺寸合格就立即入登记表并即时压托盘 alpha(消除亮屏首帧不透明);
        //          分类/手势/补位仍走下方 0.3s 延迟路径(登记幂等, 重复 addObject 无害)
        if (HNPMIsMediaSized(self.frame.size)) {
            Class preCellCls = NSClassFromString(@"NCNotificationListCell");
            UIView *p0 = self;
            while (p0 && ![p0 isKindOfClass:preCellCls]) p0 = p0.superview;
            if (p0) {
                [hnpmCardCells addObject:p0];
                // v0.0.92: 挂载回调不再同步写 alpha(与材质渲染打架 → 进度条等内容滞后,
                //          真机对照实锤) — 连扫窗口下一帧帧边界修正, 视觉无差
                HNPMStartAlphaBurst();   // v0.0.90: 挂载即启动逐帧连扫窗口
            }
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            @try {
                if (!self.window) return;
                // v0.0.70: 门槛前侦察 — 计时器卡等未过150pt门槛的内容视图此前完全静默, 无法诊断
                if (!HNPMIsMediaSized(self.frame.size)) {
                    HNPMAppendLog([NSString stringWithFormat:@"[挂载] 未登记(尺寸不足150) cls=%@ frame=%@",
                                   NSStringFromClass([self class]), NSStringFromCGRect(self.frame)]);
                    return;
                }
                Class cellClass = NSClassFromString(@"NCNotificationListCell");
                UIView *p = self;
                while (p && ![p isKindOfClass:cellClass]) p = p.superview;
                if (!p) return;
                UIView *cell = p;
                [hnpmCardCells addObject:cell];
                [hnpmCardContents addObject:self];
                HNPMAttachPanIfNeeded(cell);
                // v0.0.67: 登记期即定性(模型标识→内容特征→位置兜底), 结果缓存在单元格上
                NSString *eid = nil;
                int kind = HNPMClassifyListCell(cell, &eid);
                // v0.0.68: 特征评分上日志 — 真机实锤远程渲染导致本地特征全零, 评分只剩高度项
                HNPMCellTraits t = HNPMScanCellTraits(cell);
                int tscore = HNPMTraitsScore(t, cell.bounds.size.height);
                if (kind < 0) kind = HNPMIsBottomMostMediaCell(cell) ? 1 : 2;   // 存疑退回位置
                HNPMCellClassSet(cell, kind);
                BOOL isAnchor = (cell == hnpmHiddenCard);   // 被滑过的恢复锚(身份分类失灵也要认)
                // 侦察: 单元格/内容的 frame + 窗口坐标 + 上两级容器类名 + 身份证据
                CGRect winR = [cell convertRect:cell.bounds toView:nil];
                CGRect winC = [self convertRect:self.bounds toView:nil];
                NSString *p1 = [[cell superview] class] ? NSStringFromClass([[cell superview] class]) : @"无";
                NSString *p2 = [[cell superview] superview] ? NSStringFromClass([[cell superview] superview].class) : @"无";
                HNPMAppendLog([NSString stringWithFormat:@"[卡片] 登记 类别%d eid=%@ 按钮%d 滑条%d 时间标签%d 评分%d 锚%d 单元格 frame=%@ win=%@ 内容 frame=%@ win=%@ 容器=%@/%@",
                               kind, eid ?: @"(nil)",
                               t.buttons, t.sliders, t.timeLabels, tscore, isAnchor ? 1 : 0,
                               NSStringFromCGRect(cell.frame), NSStringFromCGRect(winR),
                               NSStringFromCGRect(self.frame), NSStringFromCGRect(winC), p1, p2]);
                if (HNPMCardHiddenGet(cell) || (hnpmHidden && (kind == 1 || isAnchor))) {
                    // 用户左滑藏过 / 音乐隐藏期被系统重建(类别1 或 恢复锚) → 保持隐藏
                    if (hnpmHidden && (kind == 1 || isAnchor)) HNPMCardHiddenSet(cell, YES);
                    self.hidden = YES;
                    cell.hidden = YES;
                    cell.transform = CGAffineTransformIdentity;
                    HNPMCardShiftSet(cell, 0.0);
                } else if (cell.hidden || self.hidden) {
                    // 恢复期登记(系统重建) → 复原显示(音乐卡与实时活动卡同规则)
                    self.hidden = NO;
                    cell.transform = CGAffineTransformIdentity;
                    cell.alpha = 0.0;
                    cell.hidden = NO;
                    HNPMCardShiftSet(cell, 0.0);
                    [UIView animateWithDuration:0.35 animations:^{ cell.alpha = 1.0; }];
                    HNPMAppendLog(@"[卡片] 恢复期登记 → 自动恢复显示");
                }
                HNPMApplyCardLayout(YES);   // 登记/重建后重算补位
                HNPMApplyCardBackgroundAlpha(cell, kind);   // v0.0.71: 背景材质层压透明(每次登记重申)
                HNPMStartAlphaBurst();   // v0.0.90: 延迟登记应用后也开连扫窗口(覆盖重建缝隙期)
                // v0.0.69: 在场卡的登记若与被抑制的实时活动身份匹配 → 解除岛抑制(活动重新呈现了)
                if (!HNPMCardHiddenGet(cell) && !cell.hidden) {
                    HNPMClearActivitySuppressionIfMatch(cell, kind);
                }
            } @catch (NSException *e) {}
        });
    } @catch (NSException *e) {}
}
%end
%end

// 灵动岛: 元素内容视图(锁图标+媒体图标)

// v0.0.88: 亮屏后系统重建/重置锁屏托盘冲掉透明度 → 托盘挂载/布局时即时重申
//         (真实触发点以真机日志为准; didMoveToWindow 覆盖重建, layoutSubviews 覆盖复用与重排)
// (PLPlatterView 声明已前移至文件头部 v0.0.99, 此处不再重复)

%group HNPMPlatterReset
%hook PLPlatterView
- (void)didMoveToWindow {
    %orig;
    @try {
        if (!self.window) {
            HNPMCoverDetach(self);   // v0.1.3: 托盘离窗摘罩(无bg期罩层挂托盘上层, 防孤儿罩层)
            return;
        }
        HNPMPlatterReapplyOnLayout(self);
    } @catch (NSException *e) {}
}
- (void)layoutSubviews {
    %orig;
    @try { HNPMPlatterReapplyOnLayout(self); } @catch (NSException *e) {}
}
// v0.0.99: 系统若用"整体换背景视图"的方式重置(而非写 alpha), 在同一调用栈内就地重申
- (void)setBackgroundView:(UIView *)v {
    %orig;
    @try {
        NSNumber *t = objc_getAssociatedObject(self, &kHNPMTargetAlphaKey);
        if (t && v) {
            CGFloat target = t.doubleValue;
            HNPMMarkTargetAlpha(v, target);
            if (fabs(v.alpha - target) > 0.01) HNPMSetAlphaNoAnim(v, target);
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (now - sHNPMCoerceLastLog > 1.0) {
                sHNPMCoerceLastLog = now;
                HNPMAppendLog([NSString stringWithFormat:@"[透明] 背景视图被替换(%@), 已就地重申→%.2f",
                               NSStringFromClass([v class]), target]);
            }
        }
    } @catch (NSException *e) {}
}
// v0.0.99: 配方写入探测 — 看系统亮屏重置是否会动 materialRecipe(若动, 配方路线可被动防御)
// v0.1.4: v0.1.3 日志实测 — 配方写入(=系统亮屏重置开始)比卡片登记早 ~1.5s
//         (10:49:24.877 配方写入 vs 26.591 登记), 且"盖托盘层"因卡片未登记从未触发。
//         此 hook 是我们拥有的最早可靠信号: %orig 后直接对托盘应用罩层(无 bg 期盖托盘层,
//         bg 已在则盖 bg), 并开连扫窗口 — 首帧白底窗口从"等登记 ~1.5s"压到重置序列起点。
- (void)setMaterialRecipe:(long long)r {
    @try {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - sHNPMCoerceLastLog > 1.0) {
            sHNPMCoerceLastLog = now;
            HNPMAppendLog([NSString stringWithFormat:@"[透明] 配方写入 %lld(系统)", r]);
        }
    } @catch (NSException *e) {}
    %orig;
    @try {
        // v0.1.7: v0.1.6 配方时链裁决 — 配方写入时刻祖先链是
        //         PLPlatterView ← NCNotificationListSupplementaryHostingView(0,0,未挂窗),
        //         单元格 NCNotificationListCell 还没接上 → 查 Cell 永远失败。
        //         SupplementaryHostingView 就是"正在播放"补充卡的专属宿主, 比 Cell 更精准:
        //         找到它即视为音乐卡托盘(无需尺寸/挂窗检查), 立即应用罩层。
        CGFloat a = HNPMBgAlpha();
        if (HNPMCoverMode() && a < 0.99) {
            Class hostCls = NSClassFromString(@"NCNotificationListSupplementaryHostingView");
            Class cellCls = NSClassFromString(@"NCNotificationListCell");
            UIView *p = self, *host = nil, *cell = nil;
            int guard = 0;
            while (p && guard++ < 12) {
                if (hostCls && !host && [p isKindOfClass:hostCls]) host = p;
                if (cellCls && !cell && [p isKindOfClass:cellCls]) cell = p;
                p = p.superview;
            }
            BOOL ok = (host != nil) ||
                      (cell && (HNPMIsMediaSized(cell.frame.size) || !cell.window || CGRectIsEmpty(cell.frame)));
            if (ok) {
                if (HNPMPlatterApplyCover(self, a) > 0) HNPMStartAlphaBurst();
            }
        }
    } @catch (NSException *e) {}
}
%end
%end

// ---- v0.0.98: 材质写入被动钳制 ----
// v0.0.97 日志裁决: 亮屏时场景宿主包装视图 a=1.00 p=1.00 全程无渐显(截断零命中),
// 但卡片登记每 3~4s 重建一次且与我们的主动 alpha 写入时间相关(写入→重建→歌词暗 ~1s)。
// 结论: 主动写入本身是扰动源。本组把"亮屏后系统把背景冲回不透明"的防御从
// "我们侦测漂移→帧边界主动写"(仍是写事件) 改为 "系统调用 setAlpha: 时在同一调用栈内
// 钳回目标值" — 不新增写事件, 系统材质配置按我们的值一次成型。
// 登记路径/巡逻/连扫保留作兜底(系统若绕过 setAlpha: 直改 layer, 仍走旧链路)。
// ---- v0.0.98/99: 材质写入被动钳制 ----
@interface MTMaterialView : UIView @end
%group HNPMAlphaCoerce
// v0.0.99: MTMaterialView 若自己实现了 setAlpha:(), 系统 reset 走它的实现, 不会经过
//          UIView 的 hook —— 这就是 v0.0.98 钳制零命中的最可能原因。双 hook 互补。
%hook UIView
- (void)setAlpha:(CGFloat)a {
    %orig(HNPMCoerceAlphaValue(self, a));
}
%end
%hook MTMaterialView
- (void)setAlpha:(CGFloat)a {
    %orig(HNPMCoerceAlphaValue(self, a));
}
%end
%end

%group HNPMIslandElement
%hook _SAUIElementViewContentView
- (void)didMoveToWindow {
    %orig;
    @try {
        if (!self.window) return;
        [hnpmIslandViews addObject:self];
        // v0.0.45: 隐藏期间系统新建的媒体内容 → 延迟 0.3s 待宽度稳定后判定并保持隐藏
        // v0.0.66: 直改前动态查岛侧模式(模式<2 让位 NativeIsland), 不再依赖注册时机
        if (hnpmHidden) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                @try {
                    if (hnpmIslandLinked && HNPMIslandMode() >= 2 && self.window && HNPMIsIslandMediaView(self)) { self.hidden = YES; HNPMBumpFastPhase(); }
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
        // v0.0.66: 直改前动态查岛侧模式(模式<2 让位 NativeIsland), 不再依赖注册时机
        if (hnpmHidden) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                @try {
                    if (hnpmIslandLinked && HNPMIslandMode() >= 2 && self.window && HNPMIsIslandMediaView(self)) { self.hidden = YES; HNPMBumpFastPhase(); }
                } @catch (NSException *e) {}
            });
        }
    } @catch (NSException *e) {}
}
%end
%end

#pragma mark - 入口

__attribute__((constructor)) static void HNPMRawCtor(void) {
    HNPMAppendLog(@"v0.1.44: dylib 构造函数已执行(dyld 加载成功)");
}

// v0.0.50/51: 岛元素抑制策略钩子 — 隐藏期让系统把 NowPlaying 元素当作"应被抑制",
// 沿用苹果自己的抑制机制 → 岛回默认布局(待机短胶囊+信号图标), 活动元素不受影响。
// v0.0.51 另钩 elementIdentifier 跟踪元素实例(元素被抑制后 _currentFirstElement 变 nil)
%group HNPMIslandSuppression
%hook SBSystemApertureSceneElement

// v0.0.51: 元素跟踪 — 记录见过的 NowPlaying 元素(弱引用), 供解除抑制时定位
// v0.0.69: 另跟踪 activity: 实时活动元素(弱引用), 供活动岛联动定位
- (NSString *)elementIdentifier {
    NSString *v = %orig;
    @try {
        if (hnpmElementTable && [v isKindOfClass:[NSString class]]) {
            @synchronized(hnpmElementTable) {
                if ([(NSString *)v containsString:@"NowPlaying"]
                    && ![hnpmElementTable containsObject:self]) [hnpmElementTable addObject:self];
            }
            @synchronized(hnpmActivityTable) {
                if ([(NSString *)v hasPrefix:@"activity:"]
                    && ![hnpmActivityTable containsObject:self]) [hnpmActivityTable addObject:self];
            }
        }
    } @catch (NSException *e) {}
    return v;
}

- (BOOL)requiresSuppressionFromSystemAperture {
    if (hnpmHidden && HNPMIsNowPlayingElement(self)) return YES;
    if (hnpmActivitySuppress && HNPMIsActivityElement(self)) return YES;   // v0.0.69: 实时活动联动
    return %orig;
}

- (BOOL)shouldSuppressElementWhileOnCoversheet {
    if (hnpmHidden && HNPMIsNowPlayingElement(self)) return YES;
    if (hnpmActivitySuppress && HNPMIsActivityElement(self)) return YES;
    return %orig;
}

- (BOOL)shouldSuppressElementWhilePresentingNoAppsOrScenes {
    if (hnpmHidden && HNPMIsNowPlayingElement(self)) return YES;
    if (hnpmActivitySuppress && HNPMIsActivityElement(self)) return YES;
    return %orig;
}

- (BOOL)shouldSuppressElementWhilePresentingAppWithBundleId:(id)bundleId {
    if (hnpmHidden && HNPMIsNowPlayingElement(self)) return YES;
    if (hnpmActivitySuppress && HNPMIsActivityElement(self)) return YES;
    return %orig;
}

- (BOOL)shouldSuppressElementWhilePresentingSceneWithIdentifier:(id)sceneId {
    if (hnpmHidden && HNPMIsNowPlayingElement(self)) return YES;
    if (hnpmActivitySuppress && HNPMIsActivityElement(self)) return YES;
    return %orig;
}

%end
%end

// v0.1.36: 捕获快照宿主生命周期钩子 — 类不存在时 %init 不执行(安全), 见 %ctor 守卫
%group HNPMCaptureHost
%hook NCMaterialDisplayingCaptureOnlyViewControllerView
- (void)didMoveToWindow {
    %orig;
    @try {
        HNPMCaptureHostPin((UIView *)self, @"挂窗");
        HNPMCaptureHostPinDelayed((UIView *)self, @"挂窗");
    } @catch (NSException *e) {}
}
- (void)didMoveToSuperview {
    %orig;
    @try { HNPMCaptureHostPin((UIView *)self, @"挂父"); } @catch (NSException *e) {}
}
- (void)layoutSubviews {
    %orig;
    @try { HNPMCaptureHostPin((UIView *)self, @"布局"); } @catch (NSException *e) {}
}
%end
%end

%ctor {
    @autoreleasepool {
        HNPMAppendLog(@"v0.1.44: logos %ctor 进入");
    HNPMAppendLog(HNPMCoverMode()
        ? @"[透明] 罩层模式 ON(HideNowPlaying.cover 存在 → 系统材质不动, 用自有 blur 罩层)"
        : @"[透明] 罩层模式 OFF(经典 alpha 模式; 建 /var/mobile/Documents/HideNowPlaying.cover 可切换)");

        if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/Documents/HideNowPlaying.off"]) {
            HNPMAppendLog(@"检测到开关文件 HideNowPlaying.off, 不注册任何 hook");
            return;
        }

        hnpmCardCells = [NSHashTable weakObjectsHashTable];
        hnpmCardContents = [NSHashTable weakObjectsHashTable];
        hnpmIslandViews = [NSHashTable weakObjectsHashTable];
        hnpmElementTable = [NSHashTable weakObjectsHashTable];
        hnpmActivityTable = [NSHashTable weakObjectsHashTable];   // v0.0.69: activity: 实时活动元素跟踪
        hnpmPanTarget = [[HNPMPanTarget alloc] init];
        sHNPMAlphaBurstTarget = [[HNPMBurstTarget alloc] init];   // v0.0.90: 亮屏逐帧连扫

        // v0.0.66: 宽限期时间基准 — 15 秒内岛侧模式动态评估(防 tweak 加载顺序竞态:
        // HideNowPlaying 按文件名先于 NativeIsland 注入, %ctor 时其 dylib 尚未加载)
        hnpmLaunchTime = [NSDate timeIntervalSinceReferenceDate];
        HNPMAppendLog(@"[共存] 岛侧模式: 延迟判定中(启动15秒后终判, 防加载顺序竞态)");

        void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
        if (mr) {
            hnpmGetInfo = (HNPMGetInfoFunc)dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
            // v0.0.63: 注册/注销符号 + 通知名常量(头文件实锤; dlsym 全局变量返回地址, 解引用取 CFStringRef)
            hnpmMRRegister   = (HNPMRegFunc)dlsym(mr, "MRMediaRemoteRegisterForNowPlayingNotifications");
            hnpmMRUnregister = (HNPMUnregFunc)dlsym(mr, "MRMediaRemoteUnregisterForNowPlayingNotifications");
            void *n1 = dlsym(mr, "kMRMediaRemoteNowPlayingInfoDidChangeNotification");
            void *n2 = dlsym(mr, "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification");
            hnpmInfoDidChangeName        = n1 ? (__bridge NSString *)*(CFStringRef *)n1 : nil;
            hnpmIsPlayingDidChangeName   = n2 ? (__bridge NSString *)*(CFStringRef *)n2 : nil;
            HNPMAppendLog(hnpmGetInfo ? @"MediaRemote 已加载, 播放检测可用" : @"MediaRemote 已加载, 播放检测不可用");
            HNPMAppendLog([NSString stringWithFormat:@"[监听MR] 符号: 注册%d 注销%d 通知名1:%@ 通知名2:%@",
                           hnpmMRRegister != NULL, hnpmMRUnregister != NULL,
                           hnpmInfoDidChangeName ?: @"(空)", hnpmIsPlayingDidChangeName ?: @"(空)"]);
            // 常驻进程内观察者(未注册时 MediaRemote 不推送=零开销); 注册/摘链由隐藏/恢复控制
            NSOperationQueue *mainQ = [NSOperationQueue mainQueue];
            if (hnpmInfoDidChangeName) {
                NSString *name1 = [hnpmInfoDidChangeName copy];
                hnpmMRObserver = [[NSNotificationCenter defaultCenter]
                    addObserverForName:name1 object:nil queue:mainQ
                    usingBlock:^(NSNotification *note) { HNPMNotifyHit(@"MR(InfoDidChange)"); }];
            }
            if (hnpmIsPlayingDidChangeName) {
                NSString *name2 = [hnpmIsPlayingDidChangeName copy];
                id obs2 = [[NSNotificationCenter defaultCenter]
                    addObserverForName:name2 object:nil queue:mainQ
                    usingBlock:^(NSNotification *note) { HNPMNotifyHit(@"MR(IsPlaying)"); }];
                if (!hnpmMRObserver) hnpmMRObserver = obs2;  // 观察者token任存一个作"已挂"标记
            }
            HNPMAppendLog(hnpmMRObserver ? @"[监听MR] 进程内观察者已挂(注册期才收通知)" : @"[监听MR] 观察者未挂(通知名缺失)");
        } else {
            HNPMAppendLog(@"MediaRemote 加载失败");
        }
        // v0.0.62 A/B路(Darwin/NS分布式)保留作对照 — 0.0.62 实锤两路零输出(非媒体通道);
        // v0.0.63 主监听 = MR注册(隐藏期短暂挂链, 见 [监听MR])
        HNPMPassiveListenA();
        HNPMPassiveListenB();

        if (objc_getClass("CSActivityItemContentView"))      { %init(HNPMActivityCard); HNPMAppendLog(@"hook 已注册: 媒体卡片(高度>=150 过滤)"); }
        // v0.0.88: 托盘透明重申 hook(PLPlatterView 不一定在所有注入进程都存在, 存在才注册)
        if (objc_getClass("PLPlatterView"))                  {
            %init(HNPMPlatterReset); HNPMAppendLog(@"hook 已注册: 托盘透明重申(PLPlatterView 亮屏防冲掉)");
            // v0.0.98: 材质写入被动钳制(与托盘钩子同进程注册; 登记路径先 apply 挂目标值才生效)
            %init(HNPMAlphaCoerce); HNPMAppendLog(@"hook 已注册: 材质写入被动钳制(UIView setAlpha:)");
        }
        // v0.0.66: 岛相关 hook 全部无条件注册, 行为由调用层闸门按岛侧模式动态拦截
        // (注册时机≠行为时机 — NativeIsland 无论先后加载, 宽限期终判后闸门即正确)
        if (objc_getClass("_SAUIElementViewContentView"))    { %init(HNPMIslandElement); }
        if (objc_getClass("_SAUIProvidedViewContainerView")) { %init(HNPMIslandPortal); }
        if (objc_getClass("SBSystemApertureSceneElement"))   { %init(HNPMIslandSuppression); HNPMAppendLog(@"hook 已注册: 岛元素抑制策略+元素跟踪(NowPlaying)"); }
        if (objc_getClass("NCMaterialDisplayingCaptureOnlyViewControllerView"))
            { %init(HNPMCaptureHost); HNPMAppendLog(@"hook 已注册: 捕获快照宿主钉扎(捕获时刻压卡区)"); }
        else { HNPMAppendLog(@"v0.1.37: 捕获快照宿主类不存在, 钉扎钩子未注册"); }

        // v0.0.66: 16 秒后输出终判(此时所有 tweak 必已加载, 检测结果可靠)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(16.0 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            int m = HNPMIslandMode();   // 触发冻结
            HNPMAppendLog([NSString stringWithFormat:@"[共存] 岛侧模式(终判): %@ (NativeIsland %@)",
                           HNPMIslandModeName(m),
                           (m == 2) ? @"未检出" : @"已检出/强制"]);
        });
        // v0.0.91: 亮屏/锁屏通知 → 亮屏瞬间开连扫窗口(覆盖"重置先于一切触发点"的盲区)
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                        HNPMScreenStateCB, CFSTR("com.apple.springboard.hasBlankedScreen"),
                                        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                        HNPMScreenStateCB, CFSTR("com.apple.springboard.lockstate"),
                                        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        HNPMAppendLog(@"v0.0.91: 屏幕状态通知观察者已挂");
        // v0.0.87: 设置面板(设置 → HideNowPlaying) — 改动即时生效(darwin 通知 → 清缓存/应用开关)
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                        HNPMPrefsChangedCB, CFSTR("com.aha.hidenowplaying/prefschanged"),
                                        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        HNPMAppendLog(@"v0.0.92: 设置面板通知观察者已挂");
        // v0.0.93: 空闲巡逻(0.5s 只读一次, 无在场卡自动停) — 堵"空闲期静默重置无事件触发"盲区
        HNPMIdleAlphaCheck();
        HNPMHookBackdrop();
        HNPMCapturePersistLoop();   // v0.1.34: 卡区捕获快照持续压住(0.5s 一拍, 自续)
        HNPMAppendLog(@"v0.1.44: 卡区透明持续生效循环已启动");
        HNPMAppendLog(@"v0.1.44: 空闲巡逻已启动");
        HNPMAppendLog(@"v0.1.44: %ctor 正常完成");
    }
}
