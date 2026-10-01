// HideNowPlaying v0.0.3 — 探针版 2(无任何 hook)
//
// 相比 v0.0.2 的变化:
//   1. 去掉链接参数 -Wl,-undefined,dynamic_lookup(排除链接变量)
//   2. 最早的原始构造函数里就写日志(区分"dyld 加载崩"还是"logos %ctor 崩")
//   3. 支持紧急开关: 存在 /var/mobile/Documents/HideNowPlaying.off 文件时 %ctor 直接返回
//
// 日志文件: /var/mobile/Documents/HideNowPlaying.log

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <stdlib.h>

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

// 最早的入口: dyld 加载本 dylib 后、logos %ctor 之前执行
__attribute__((constructor)) static void HNPMRawCtor(void) {
    HNPMAppendLog(@"v0.0.3 探针: dylib 构造函数已执行(dyld 加载成功)");
}

%ctor {
    @autoreleasepool {
        HNPMAppendLog(@"v0.0.3 探针: logos %ctor 已进入");

        // 紧急开关: 创建 /var/mobile/Documents/HideNowPlaying.off 即可让插件完全不干活
        if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/Documents/HideNowPlaying.off"]) {
            HNPMAppendLog(@"检测到开关文件 HideNowPlaying.off, 探针直接退出");
            return;
        }

        NSMutableString *report = [NSMutableString string];
        [report appendFormat:@"进程: %s", getprogname()];

        NSArray *candidates = @[
            @"SBDashBoardAggregatedMusicPlayerViewController",
            @"SBDashBoardNowPlayingViewController",
            @"SBLockScreenNowPlayingViewController",
            @"SBFloatingMediaControlsViewController",
            @"MRMediaControlsViewController",
        ];
        [report appendString:@" | 候选类: "];
        for (NSString *name in candidates) {
            [report appendFormat:@"%@=%@ ", name, objc_getClass(name.UTF8String) ? @"Y" : @"N"];
        }
        HNPMAppendLog(report);

        // 收集系统里所有播放器相关类名
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
                HNPMAppendLog([NSString stringWithFormat:@"系统相关类(%lu个):\n%@", (unsigned long)found.count, [found componentsJoinedByString:@"\n"]]);
            }
        } @catch (NSException *exception) {
            HNPMAppendLog(@"类名收集异常");
        }

        HNPMAppendLog(@"v0.0.3 探针: %ctor 正常完成");
    }
}
