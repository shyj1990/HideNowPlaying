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
static BOOL HNPMPrefCardHidden(void);   // v0.0.78: 前置声明(设置面板开关, 定义在后)
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
                            // v0.0.78: 设置"隐藏音乐卡片"=开 → 暂停恢复不再还原(保持默认隐藏)
                            if (HNPMPrefCardHidden()) {
                                HNPMAppendLog(@"[设置] 隐藏音乐卡片=开 → 忽略暂停恢复(保持隐藏)");
                            } else {
                                HNPMSetHidden(NO, @"检测到暂停后继续播放", YES);
                            }
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
// v0.0.78: 配置优先级 = 设置面板(CFPreferences bgAlpha) > 文件(/var/mobile/Documents/HideNowPlaying.alpha)
//          > 默认 0.55; 1.0 = 关闭功能; 5s 缓存防频繁读盘, 面板改动经 darwin 通知即时清缓存。
static CGFloat hnpmBgAlphaCached = -1.0;
static CFAbsoluteTime hnpmBgAlphaCachedAt = 0;
static void HNPMBgAlphaInvalidate(void) { hnpmBgAlphaCached = -1.0; }

// v0.0.78: 设置面板"隐藏音乐卡片"开关(CFPreferences)
static BOOL HNPMPrefCardHidden(void) {
    Boolean ok = NO;
    BOOL v = CFPreferencesGetAppBooleanValue(CFSTR("cardHidden"), CFSTR("com.aha.hidenowplaying"), &ok);
    return ok ? (BOOL)v : NO;
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

// v0.0.75: 托盘内部结构一次性诊断 — 确认 backgroundView(白底)/customContentView(内容)分层,
//          供排障; 每次解锁进程只 dump 一次。
static BOOL sHNPMPlatterDiagDumped = NO;
static void HNPMPlatterDiagDump(UIView *platter, UIView *bg, NSString *via) {
    if (sHNPMPlatterDiagDumped) return;
    sHNPMPlatterDiagDumped = YES;
    @try {
        NSMutableArray *rows = [NSMutableArray array];
        [rows addObject:[NSString stringWithFormat:@"托盘%@ f=%@ via=%@(%@)", NSStringFromClass([platter class]), NSStringFromCGRect(platter.frame), via, NSStringFromCGRect(bg.frame)]];
        for (UIView *s in platter.subviews) {
            [rows addObject:[NSString stringWithFormat:@"%@ f=%@ a=%.2f h=%d", NSStringFromClass([s class]), NSStringFromCGRect(s.frame), s.alpha, s.isHidden ? 1 : 0]];
        }
        HNPMAppendLog([NSString stringWithFormat:@"[透明·诊断] %@", [rows componentsJoinedByString:@" || "]]);
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
        if (a >= 0.99) return;   // 1.0 = 功能关闭
        NSMutableSet *touched = [NSMutableSet set];
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
                        // v0.0.75: 只压托盘的"背景子层" — 真机实测(v0.0.74)压整个托盘时内容
                        //          (customContentView 里的 hostedView)被连带淡化 = 幽灵卡复现。
                        //          头文件分层: backgroundView(白底材质) / customContentView(内容)。
                        UIView *bg = nil; NSString *via = @"";
                        @try {
                            id x = [v valueForKey:@"backgroundView"];
                            if ([x isKindOfClass:[UIView class]]) { bg = x; via = @"backgroundView"; }
                        } @catch (NSException *e) {}
                        if (!bg) {
                            @try {
                                id x = [v valueForKey:@"backgroundMaterialView"];
                                if ([x isKindOfClass:[UIView class]]) { bg = x; via = @"backgroundMaterialView"; }
                            } @catch (NSException *e) {}
                        }
                        if (bg) {
                            if (fabs(bg.alpha - a) > 0.01) bg.alpha = a;
                            [touched addObject:bg];
                            pHits++; pVia = via;
                            HNPMPlatterDiagDump(v, bg, via);
                        } else {
                            // 托盘无背景子层(罕见) → 整托盘淡化(旧路兜底, 内容会连带)
                            if (fabs(v.alpha - a) > 0.01) v.alpha = a;
                            [touched addObject:v];
                            pHits++; pVia = @"整托盘";
                        }
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

// v0.0.78: 设置面板"隐藏音乐卡片"开关的应用 — 开=找在场媒体卡走与左滑一致的隐藏链
//          (先 MR 裁决有播放会话才动手, 防止误伤纯实时活动场景); 关=立即恢复显示。
static void HNPMPrefApplyCardHidden(void) {
    if (!HNPMPrefCardHidden()) {
        if (hnpmHidden) {
            HNPMSetHidden(NO, @"设置开关恢复", YES);
            HNPMAppendLog(@"[设置] 隐藏音乐卡片=关 → 恢复显示");
        }
        return;
    }
    if (hnpmHidden) return;    // 已在隐藏态
    if (!hnpmGetInfo) return;  // 无 MR 符号: 保守不自动藏(与左滑裁决同门槛)
    hnpmGetInfo(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(CFDictionaryRef info) {
        BOOL hasInfo = (info != NULL && CFDictionaryGetCount(info) > 0);
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                if (!HNPMPrefCardHidden() || hnpmHidden) return;
                if (!hasInfo) {
                    HNPMAppendLog(@"[设置] 隐藏音乐卡片=开 → 无播放会话(纯实时活动场景)不自动藏");
                    return;
                }
                UIView *target = nil;
                CGFloat bestY = -CGFLOAT_MAX;
                for (UIView *c in hnpmCardCells) {
                    if (!c.window || c.hidden || HNPMCardHiddenGet(c) || !HNPMCellHasLiveMedia(c)) continue;
                    CGRect cr = [c convertRect:c.bounds toView:nil];
                    CGFloat cy = cr.origin.y + cr.size.height;
                    if (cy > bestY) { bestY = cy; target = c; }
                }
                if (!target) {
                    HNPMAppendLog(@"[设置] 隐藏音乐卡片=开 → 暂无在场媒体卡(等登记触发)");
                    return;
                }
                HNPMHideCard(target);
                HNPMSetHidden(YES, @"设置-隐藏音乐卡片", YES);
                HNPMStartRestorePolling();
                HNPMAppendLog(@"[设置] 隐藏音乐卡片=开 → 自动隐藏(岛联动)");
            } @catch (NSException *e) {}
        });
    });
}

// v0.0.78: 设置面板改动回调(Root.plist 的 PostNotification → darwin notify)
//          清透明度缓存 + 立即应用隐藏开关(免等登记/轮询)。
static void HNPMPrefsChangedCB(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    CFPreferencesAppSynchronize(CFSTR("com.aha.hidenowplaying"));
    HNPMBgAlphaInvalidate();
    dispatch_async(dispatch_get_main_queue(), ^{
        @try { HNPMPrefApplyCardHidden(); } @catch (NSException *e) {}
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
                // v0.0.69: 在场卡的登记若与被抑制的实时活动身份匹配 → 解除岛抑制(活动重新呈现了)
                if (!HNPMCardHiddenGet(cell) && !cell.hidden) {
                    HNPMClearActivitySuppressionIfMatch(cell, kind);
                }
                // v0.0.78: 设置"隐藏音乐卡片"=开 → 登记后自动隐藏(覆盖锁屏进入/respring/卡片重建;
                //          HNPMPrefApplyCardHidden 内部有 MR 会话裁决, 防误伤纯实时活动场景)
                if (!hnpmHidden && HNPMPrefCardHidden() && !HNPMCardHiddenGet(cell) && HNPMCellHasLiveMedia(cell)) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        @try { HNPMPrefApplyCardHidden(); } @catch (NSException *e) {}
                    });
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
    HNPMAppendLog(@"v0.0.78: dylib 构造函数已执行(dyld 加载成功)");
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

%ctor {
    @autoreleasepool {
        HNPMAppendLog(@"v0.0.78: logos %ctor 进入");

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
        // v0.0.66: 岛相关 hook 全部无条件注册, 行为由调用层闸门按岛侧模式动态拦截
        // (注册时机≠行为时机 — NativeIsland 无论先后加载, 宽限期终判后闸门即正确)
        if (objc_getClass("_SAUIElementViewContentView"))    { %init(HNPMIslandElement); }
        if (objc_getClass("_SAUIProvidedViewContainerView")) { %init(HNPMIslandPortal); }
        if (objc_getClass("SBSystemApertureSceneElement"))   { %init(HNPMIslandSuppression); HNPMAppendLog(@"hook 已注册: 岛元素抑制策略+元素跟踪(NowPlaying)"); }

        // v0.0.66: 16 秒后输出终判(此时所有 tweak 必已加载, 检测结果可靠)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(16.0 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            int m = HNPMIslandMode();   // 触发冻结
            HNPMAppendLog([NSString stringWithFormat:@"[共存] 岛侧模式(终判): %@ (NativeIsland %@)",
                           HNPMIslandModeName(m),
                           (m == 2) ? @"未检出" : @"已检出/强制"]);
        });
        // v0.0.78: 设置面板(设置 → HideNowPlaying) — 改动即时生效(darwin 通知 → 清缓存/应用开关)
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                        HNPMPrefsChangedCB, CFSTR("com.aha.hidenowplaying/prefschanged"),
                                        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        HNPMAppendLog(@"v0.0.78: 设置面板通知观察者已挂");
        HNPMAppendLog(@"v0.0.78: %ctor 正常完成");
    }
}
