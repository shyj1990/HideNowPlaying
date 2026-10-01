// HideNowPlaying v0.0.2 — 安全探针版(不含任何 hook)
//
// 目的:
//   1. 验证插件能被 roothide/ElleKit 安全加载(上一版导致黑屏,先隔离加载层问题)
//   2. 收集 iOS 17 上真实存在的播放器相关类名,用于下一版精确挂钩
//
// 日志文件: /var/mobile/Documents/HideNowPlaying.log (用 Filza 打开查看)

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <stdlib.h>

// 写日志到文件(SpringBoard 以 mobile 用户运行,/var/mobile/Documents 可写;
// 全程 @try 包裹,写失败也不影响系统)
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
        // 探针绝不能崩
    }
}

%ctor {
    @autoreleasepool {
        NSMutableString *report = [NSMutableString string];

        // 1) 确认加载到了正确进程
        [report appendFormat:@"进程: %s", getprogname()];
        [report appendString:@" | 插件加载成功(探针版,无任何 hook)"];

        // 2) 检查候选类是否存在
        NSArray *candidates = @[
            @"SBDashBoardAggregatedMusicPlayerViewController",
            @"SBDashBoardNowPlayingViewController",
            @"SBLockScreenNowPlayingViewController",
            @"SBFloatingMediaControlsViewController",
            @"MRMediaControlsViewController",
        ];
        [report appendString:@"\n--- 候选类检查 ---"];
        for (NSString *name in candidates) {
            Class cls = objc_getClass(name.UTF8String);
            [report appendFormat:@"\n%@ : %@", name, cls ? @"存在" : @"不存在"];
        }

        // 3) 收集系统里所有播放器相关的类名(下一版挂钩用)
        @try {
            unsigned int count = 0;
            Class *classes = objc_copyClassList(&count);
            if (classes) {
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
                [report appendFormat:@"\n--- 系统相关类(共%lu个) ---\n%@", (unsigned long)found.count, [found componentsJoinedByString:@"\n"]];
            }
        } @catch (NSException *exception) {
            [report appendString:@"\n类名收集失败"];
        }

        HNPMAppendLog(report);
    }
}
