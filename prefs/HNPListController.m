#import <UIKit/UIKit.h>
#import <dlfcn.h>

// v0.0.79: 弃用运行时 objc_allocateClassPair(它的 class_getImageName 拿不到本 bundle 镜像 →
// PSListController -bundle = bundleForClass 落到 Settings 主程序 → 任意 plist 都找不到 → 空页),
// 改为「假头文件 + 编译期子类」— Preferences 框架只出现在 @interface 声明里, 从不链接其符号,
// 运行时由 Settings 进程内已加载的 Preferences.framework 解析父类。编译进 bundle 的真实类
// 自动携带正确的镜像信息, bundleForClass 天然正确(所有 tweak 的标准做法)。
//
// 页面改为代码构建 specifiers: ①锁屏左滑隐藏 总开关(默认开) ②背景透明度 自定义滑条 cell
// (UISlider + 实时数值标签, 拖动即写 CFPreferences 并 post darwin 通知)。

// ---- 私有框架最小声明(仅编译期用, 不链接) ----
@interface PSSpecifier : NSObject
+ (id)groupSpecifierWithNamed:(NSString *)name footerText:(NSString *)footer;
+ (id)preferenceSpecifierNamed:(NSString *)name target:(id)target set:(SEL)set get:(SEL)get detail:(id)detail cell:(NSInteger)cellType edit:(id)edit;
- (void)setProperty:(id)property forKey:(NSString *)key;
- (id)propertyForKey:(NSString *)key;
@end

@interface PSListController : UIViewController
- (void)reloadSpecifiers;
@end

// ---- 设备侧日志(与主 tweak 同一文件) ----
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

static NSString * const HNPDomain = @"com.aha.hidenowplaying";
static NSString * const HNPNotifName = @"com.aha.hidenowplaying/prefschanged";

static void HNPPostPrefsChanged(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)HNPDomain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)HNPNotifName, NULL, NULL, YES);
}

// ---- 自定义滑条 cell: UISlider + 实时数值标签 ----
@interface HNPSliderCell : UITableViewCell
- (id)initWithSpecifier:(PSSpecifier *)specifier;
@end

@implementation HNPSliderCell {
    UISlider *_slider;
    UILabel *_label;
    NSString *_key;
}

- (id)initWithSpecifier:(PSSpecifier *)spec {
    self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    if (self) {
        CGFloat v = 0.55, mn = 0.05, mx = 1.0;
        NSNumber *p;
        _key = [spec propertyForKey:@"key"] ?: @"bgAlpha";
        if ((p = [spec propertyForKey:@"min"])) mn = p.doubleValue;
        if ((p = [spec propertyForKey:@"max"])) mx = p.doubleValue;
        CFTypeRef pv = CFPreferencesCopyAppValue((__bridge CFStringRef)_key, (__bridge CFStringRef)HNPDomain);
        if (pv) { v = [(__bridge NSNumber *)pv doubleValue]; CFRelease(pv); }
        else if ((p = [spec propertyForKey:@"default"])) v = p.doubleValue;
        if (v < mn) v = mn;
        if (v > mx) v = mx;

        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.backgroundColor = UIColor.clearColor;

        _slider = [[UISlider alloc] initWithFrame:CGRectZero];
        _slider.minimumValue = mn;
        _slider.maximumValue = mx;
        _slider.value = (float)v;
        [_slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
        [self.contentView addSubview:_slider];

        _label = [[UILabel alloc] initWithFrame:CGRectZero];
        _label.textAlignment = NSTextAlignmentRight;
        _label.font = [UIFont monospacedDigitSystemFontOfSize:15.0 weight:UIFontWeightRegular];
        _label.textColor = [UIColor secondaryLabelColor];
        [self updateLabel:v];
        [self.contentView addSubview:_label];
        HNPPrefsLog(@"HNPSliderCell 构建完成");
    }
    return self;
}

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)rid {
    // 兜底: 若 PSListController 走标准 init 路径也不崩(仅无滑条)
    return [super initWithStyle:style reuseIdentifier:rid];
}

- (void)updateLabel:(CGFloat)v {
    _label.text = [NSString stringWithFormat:@"%.2f", v];
}

- (void)sliderChanged:(UISlider *)s {
    double v = s.value;
    [self updateLabel:v];
    CFPreferencesSetAppValue((__bridge CFStringRef)_key, (__bridge CFTypeRef)@(v), (__bridge CFStringRef)HNPDomain);
    HNPPostPrefsChanged();   // 主 tweak darwin 回调 → 清缓存即时应用
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width;
    CGFloat h = self.contentView.bounds.size.height;
    _label.frame = CGRectMake(w - 66.0, 0, 56.0, h);
    _slider.frame = CGRectMake(20.0, (h - 31.0) / 2.0, w - 66.0 - 20.0 - 12.0, 31.0);
}

@end

// ---- 列表控制器(编译期子类, 镜像信息正确) ----
static Class HNPValCellClass(void) { return [HNPSliderCell class]; }

@interface HNPListController : PSListController
@end

@implementation HNPListController {
    NSArray *_specs;
}

- (NSArray *)specifiers {
    if (_specs) return _specs;
    [self setTitle:@"HideNowPlaying"];
    NSMutableArray *m = [NSMutableArray array];

    [m addObject:[PSSpecifier groupSpecifierWithNamed:@""
            footerText:@"开启后，锁屏音乐卡/实时活动卡支持左滑隐藏并同步隐藏灵动岛；暂停后继续播放会自动恢复显示。关闭后左滑手势不再生效，若已隐藏会立即恢复。"]];

    PSSpecifier *sw = [PSSpecifier preferenceSpecifierNamed:@"锁屏左滑隐藏"
            target:nil set:nil get:nil detail:nil cell:1 edit:nil];
    [sw setProperty:HNPDomain forKey:@"defaults"];
    [sw setProperty:@"swipeHide" forKey:@"key"];
    [sw setProperty:@YES forKey:@"default"];
    [sw setProperty:HNPNotifName forKey:@"PostNotification"];
    [m addObject:sw];

    [m addObject:[PSSpecifier groupSpecifierWithNamed:@""
            footerText:@"卡片背景透明度：只淡化白色背景板，文字/封面不受影响。1.0 = 不透明(功能关闭)，0.05 = 接近全透。拖动即时生效。"]];

    PSSpecifier *sl = [PSSpecifier preferenceSpecifierNamed:@"背景透明度"
            target:nil set:nil get:nil detail:nil cell:4 edit:nil];
    [sl setProperty:@0.05 forKey:@"min"];
    [sl setProperty:@1.0 forKey:@"max"];
    [sl setProperty:@0.55 forKey:@"default"];
    [sl setProperty:@"bgAlpha" forKey:@"key"];
    [sl setProperty:HNPDomain forKey:@"defaults"];
    [sl setProperty:HNPValCellClass() forKey:@"cellClass"];
    [m addObject:sl];

    _specs = m;
    HNPPrefsLog(@"specifiers 构建完成(代码构建)");
    return _specs;
}

@end

__attribute__((constructor))
static void HNPPrefsBundleCtor(void) {
    @autoreleasepool {
        HNPPrefsLog(@"bundle ctor 进入(编译期子类版)");
    }
}
