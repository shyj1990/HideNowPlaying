#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

// v0.0.76: 运行时注册 HNPListController(PSListController 子类) — 彻底避免链接私有框架
// Preferences(SDK 无 tbd, Xcode 15 新链接器也不认手写 tbd 文本)。
//
// v0.0.78: 真机两轮空白页实锤根因 — PSListController 的 -bundle 实现为
//   [NSBundle bundleForClass:[self class]](18.2 反编译), 而对 objc_allocateClassPair
//   运行时创建的类 class_getImageName 拿不到本 bundle 镜像 → bundleForClass 退化成
//   Settings 主程序 → 在错误 bundle 里找 plist → 永远空页无标题。
//   修复: 给运行时类挂 bundle 重写 — dladdr 取本 dylib 真实路径 → 其父目录即
//   HideNowPlayingPrefs.bundle → bundleWithPath: 返回正确 NSBundle。
//   附 [PREFS] 设备侧日志(与主 tweak 同一日志文件), 下一轮可验证 bundle 是否真被加载。

static void HNPPrefsLog(NSString *text) {
    @try {
        FILE *f = fopen("/var/mobile/Documents/HideNowPlaying.log", "a");
        if (!f) return;
        time_t t = time(NULL);
        struct tm tmv;
        localtime_r(&t, &tmv);
        fprintf(f, "[%04d-%02d-%02d %02d:%02d:%02d +0000] [PREFS] %s\n",
                tmv.tm_year + 1900, tmv.tm_mon + 1, tmv.tm_mday,
                tmv.tm_hour, tmv.tm_min, tmv.tm_sec,
                [text UTF8String]);
        fclose(f);
    } @catch (__unused id e) {}
}

// 本 prefs bundle 的路径: dladdr 命中本函数所在 dylib = .../HideNowPlayingPrefs.bundle/HideNowPlayingPrefs
static NSString *HNPPrefsOwnBundlePath(void) {
    static NSString *cached;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Dl_info info;
        if (dladdr((void *)HNPPrefsOwnBundlePath, &info) && info.dli_fname) {
            cached = [[NSString stringWithUTF8String:info.dli_fname] stringByDeletingLastPathComponent];
        }
    });
    return cached;
}

// -bundle 重写: 返回本 bundle; 拿不到则走父类默认
static id HNPPrefs_bundle(id self, SEL _cmd) {
    @try {
        static BOOL logged = NO;
        NSString *path = HNPPrefsOwnBundlePath();
        if (path) {
            NSBundle *b = [NSBundle bundleWithPath:path];
            if (b && b.bundleIdentifier) {
                if (!logged) {
                    logged = YES;
                    BOOL hasLabelPlist = [b pathForResource:@"HideNowPlaying" ofType:@"plist"] != nil;
                    HNPPrefsLog([NSString stringWithFormat:@"bundle重写生效 path=%@ bundleId=%@ HideNowPlaying.plist存在=%d",
                                 path, b.bundleIdentifier, hasLabelPlist]);
                }
                return b;
            }
        }
        if (!logged) { logged = YES; HNPPrefsLog([NSString stringWithFormat:@"bundle重写未命中 path=%@ → 走父类默认", path]); }
    } @catch (__unused id e) {}
    struct objc_super sup = { (id)self, class_getSuperclass(object_getClass(self)) };
    return ((id (*)(struct objc_super *, SEL))objc_msgSendSuper)(&sup, _cmd);
}

__attribute__((constructor))
static void HNPPrefsBundleCtor(void) {
    @autoreleasepool {
        HNPPrefsLog(@"ctor 进入");
        Class superCls = NSClassFromString(@"PSListController");
        if (!superCls) { HNPPrefsLog(@"PSListController 不存在(非 Settings 进程) → 跳过注册"); return; }
        if (NSClassFromString(@"HNPListController")) { HNPPrefsLog(@"HNPListController 已存在 → 跳过"); return; }
        Class cls = objc_allocateClassPair(superCls, "HNPListController", 0);
        if (!cls) { HNPPrefsLog(@"allocateClassPair 失败!"); return; }
        if (!class_addMethod(cls, @selector(bundle), (IMP)HNPPrefs_bundle, "@@:")) {
            HNPPrefsLog(@"class_addMethod(bundle) 失败!");
        }
        objc_registerClassPair(cls);
        HNPPrefsLog([NSString stringWithFormat:@"HNPListController 注册成功 bundlePath=%@",
                     HNPPrefsOwnBundlePath() ?: @"(nil)"]);
    }
}
