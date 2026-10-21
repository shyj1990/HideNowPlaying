#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// v0.0.76: 运行时注册 HNPListController(PSListController 子类) — 彻底避免链接私有框架
// Preferences(SDK 无 tbd, Xcode 15 新链接器也不认手写 tbd 文本)。
// Bundle 二进制被 PreferenceLoader/Settings dlopen 时本构造函数执行注册类,
// Info.plist 的 NSPrincipalClass = HNPListController 随后经 NSClassFromString 命中。
// 纯 plist 驱动: PSListController 默认从 bundleForClass(=本 bundle) 读取 Root.plist。
__attribute__((constructor))
static void HNPPrefsBundleCtor(void) {
    @autoreleasepool {
        Class superCls = NSClassFromString(@"PSListController");
        if (!superCls) return;   // 不在 Settings 进程环境(异常场景)静默跳过
        if (NSClassFromString(@"HNPListController")) return;
        Class cls = objc_allocateClassPair(superCls, "HNPListController", 0);
        if (cls) objc_registerClassPair(cls);
    }
}
