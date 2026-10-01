// HideNowPlaying — 仿 iOS 27“隐藏音乐播放器”交互
//
// 功能:
//   1. 锁屏“正在播放”卡片上【左滑】→ 卡片隐藏,灵动岛播放器同步隐藏,音乐不暂停
//   2. 【暂停 → 继续播放】后 → 自动恢复显示
//
// 原理: 注入 SpringBoard,给锁屏/媒体控件视图挂左滑手势,隐藏视图本身(不碰音频通路);
//       通过 MediaRemote 广播通知监听 暂停→播放 的状态跳变来恢复。
//
// 调试: 每次注销(respring)后 syslog 会有 [HideNowPlaying] 日志,
//       并打印当前系统里所有播放器相关的类名,方便针对你的 iOS 17 精确适配。

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// MediaRemote 私有框架(SpringBoard 进程内已加载,直接声明符号即可,无需链接)
extern void MRMediaRemoteGetNowPlayingInfo(dispatch_queue_t queue, void (^completion)(CFDictionaryRef information));

#define HNPMLog(fmt, ...) NSLog(@"[HideNowPlaying] " fmt, ##__VA_ARGS__)

#pragma mark - 全局状态

static BOOL hnpmHidden = NO;                    // 当前是否处于“已隐藏”状态
static BOOL hnpmWasPlaying = NO;                // 上一次查询到的播放状态
static NSHashTable<UIView *> *hnpmHiddenViews;  // 被我们藏起来的视图(弱引用,自动清理)

#pragma mark - 隐藏 / 恢复

static void HNPMHideView(UIView *view) {
    if (!view || hnpmHidden) return;
    hnpmHidden = YES;
    [hnpmHiddenViews addObject:view];
    view.hidden = YES;
    HNPMLog(@"已隐藏播放器界面(音乐继续播放): %@", view);
}

static void HNPMUnhideAll(void) {
    if (!hnpmHidden) return;
    hnpmHidden = NO;
    for (UIView *view in hnpmHiddenViews) {
        view.hidden = NO;
    }
    [hnpmHiddenViews removeAllObjects];
    HNPMLog(@"已恢复显示播放器界面");
}

#pragma mark - 左滑手势

@interface HNPMHandler : NSObject
- (void)handleSwipe:(UISwipeGestureRecognizer *)gesture;
@end
@implementation HNPMHandler
+ (instancetype)shared {
    static HNPMHandler *handler;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ handler = [[self alloc] init]; });
    return handler;
}
- (void)handleSwipe:(UISwipeGestureRecognizer *)gesture {
    HNPMHideView(gesture.view);
}
@end

static char kHNPMGestureKey;

// 给播放器视图挂左滑手势(只挂一次),并在系统重新布局时把隐藏状态顶回去
static void HNPMSetupView(UIView *view) {
    if (!view) return;

    if (hnpmHidden && view.hidden == NO) {
        [hnpmHiddenViews addObject:view];
        view.hidden = YES;
    }

    if (!objc_getAssociatedObject(view, &kHNPMGestureKey)) {
        UISwipeGestureRecognizer *swipe = [[UISwipeGestureRecognizer alloc]
            initWithTarget:[HNPMHandler shared] action:@selector(handleSwipe:)];
        swipe.direction          = UISwipeGestureRecognizerDirectionLeft;
        swipe.delaysTouchesBegan = YES;
        swipe.delaysTouchesEnded = YES;
        [view addGestureRecognizer:swipe];
        objc_setAssociatedObject(view, &kHNPMGestureKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

#pragma mark - 播放状态监听(用于恢复显示)

// Darwin 通知本身不带数据,收到后主动查一次真实的“正在播放”信息
static void HNPMNowPlayingChanged(CFNotificationCenterRef center, void *observer,
                                  CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        MRMediaRemoteGetNowPlayingInfo(dispatch_get_main_queue(), ^(CFDictionaryRef info) {
            if (!info) return;

            NSNumber *rate = (__bridge NSNumber *)CFDictionaryGetValue(
                info, CFSTR("kMRMediaRemoteNowPlayingInfoPlaybackRate"));

            BOOL playing = rate && rate.doubleValue > 0.01;
            HNPMLog(@"播放状态更新: rate=%.2f playing=%d", rate ? rate.doubleValue : 0.0, playing);

            if (playing && !hnpmWasPlaying) {
                // 暂停 → 继续播放: 恢复显示
                HNPMUnhideAll();
            } else if (!rate && hnpmHidden) {
                // 个别 App 不提供 playbackRate,退化为“收到任意状态更新就恢复”
                HNPMUnhideAll();
            }
            hnpmWasPlaying = playing;
        });
    });
}

#pragma mark - 调试: 打印系统里的播放器相关类名(方便精确适配)

static void HNPMDumpClasses(void) {
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (!classes) return;

    NSMutableArray *found = [NSMutableArray array];
    for (unsigned int i = 0; i < count; i++) {
        NSString *name = NSStringFromClass(classes[i]);
        if ([name containsString:@"NowPlaying"] ||
            [name containsString:@"MediaControls"] ||
            [name containsString:@"DashBoard"] ||
            [name containsString:@"DynamicIsland"]) {
            [found addObject:name];
        }
    }
    free(classes);
    HNPMLog(@"本机相关类名(适配用): %@", found);
}

#pragma mark - Hook

// 各 iOS 版本的候选类声明(不存在于系统的会在运行时自动跳过)
@interface MRMediaControlsViewController : UIViewController
@end
@interface SBDashBoardAggregatedMusicPlayerViewController : UIViewController
@end
@interface SBDashBoardNowPlayingViewController : UIViewController
@end
@interface SBLockScreenNowPlayingViewController : UIViewController
@end
@interface SBFloatingMediaControlsViewController : UIViewController
@end

// iOS 16+ 统一媒体控件基类(灵动岛播放器 / 控制中心播放器)
%hook MRMediaControlsViewController
- (void)viewDidLayoutSubviews  { %orig; HNPMSetupView(self.view); }
- (void)viewWillAppear:(BOOL)animated { %orig; HNPMSetupView(self.view); }
%end

// 锁屏“正在播放”卡片 —— 不同 iOS 版本类名不同,候选同时挂着,系统里不存在哪个就自动跳过
%hook SBDashBoardAggregatedMusicPlayerViewController
- (void)viewDidLayoutSubviews  { %orig; HNPMSetupView(self.view); }
- (void)viewWillAppear:(BOOL)animated { %orig; HNPMSetupView(self.view); }
%end

%hook SBDashBoardNowPlayingViewController
- (void)viewDidLayoutSubviews  { %orig; HNPMSetupView(self.view); }
- (void)viewWillAppear:(BOOL)animated { %orig; HNPMSetupView(self.view); }
%end

%hook SBLockScreenNowPlayingViewController
- (void)viewDidLayoutSubviews  { %orig; HNPMSetupView(self.view); }
- (void)viewWillAppear:(BOOL)animated { %orig; HNPMSetupView(self.view); }
%end

%hook SBFloatingMediaControlsViewController
- (void)viewDidLayoutSubviews  { %orig; HNPMSetupView(self.view); }
- (void)viewWillAppear:(BOOL)animated { %orig; HNPMSetupView(self.view); }
%end

#pragma mark - 入口

%ctor {
    @autoreleasepool {
        hnpmHiddenViews = [NSHashTable weakObjectsHashTable];

        // 监听“正在播放”状态变化(暂停/继续播放都会广播)
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            &HNPMNowPlayingChanged,
            CFSTR("kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"),
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            &HNPMNowPlayingChanged,
            CFSTR("kMRMediaRemoteNowPlayingInfoDidChangeNotification"),
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);

        %init;
        HNPMDumpClasses();
        HNPMLog(@"加载完成 (iOS 17 rootless, 作用于 SpringBoard)");
    }
}
