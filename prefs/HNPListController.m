#import <UIKit/UIKit.h>

// v0.0.76: 设置面板列表控制器 — 纯 plist 驱动(Root.plist), 无自定义逻辑。
// Preferences 为私有框架, 头文件不在 SDK 里, 这里只做最小声明供编译链接。
@interface PSListController : UIViewController
@end

@interface HNPListController : PSListController
@end

@implementation HNPListController
@end
