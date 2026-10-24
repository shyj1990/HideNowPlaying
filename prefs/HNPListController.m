#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>

// v0.0.79: 弃用运行时 objc_allocateClassPair(它的 class_getImageName 拿不到本 bundle 镜像 →
// PSListController -bundle = bundleForClass 落到 Settings 主程序 → 任意 plist 都找不到 → 空页),
// 改为「假头文件 + 编译期子类」— Preferences 框架只出现在 @interface 声明里, 从不链接其符号,
// 运行时由 Settings 进程内已加载的 Preferences.framework 解析父类。编译进 bundle 的真实类
// 自动携带正确的镜像信息, bundleForClass 天然正确(所有 tweak 的标准做法)。
//
// 页面改为代码构建 specifiers: ①锁屏左滑隐藏 总开关(默认开) ②背景透明度 自定义滑条 cell
// (UISlider + 实时数值标签, 拖动即写 CFPreferences 并 post darwin 通知)。

// ---- 私有框架最小声明(仅编译期用, 不链接) ----
// v0.0.80: groupSpecifierWithNamed:footerText: 是越狱生态 category, 原生不存在(iOS17 真机
// 实锤 unrecognized selector 闪退) → 用原生 groupSpecifierWithName: + footerText 属性。
@interface PSSpecifier : NSObject
+ (id)groupSpecifierWithName:(NSString *)name;
+ (id)preferenceSpecifierNamed:(NSString *)name target:(id)target set:(SEL)set get:(SEL)get detail:(id)detail cell:(NSInteger)cellType edit:(id)edit;
- (void)setProperty:(id)property forKey:(NSString *)key;
- (id)propertyForKey:(NSString *)key;
@end

@interface PSListController : UIViewController
- (void)reloadSpecifiers;
- (void)setSpecifiers:(id)specifiers;   // v0.0.87: 官方 setter — 渲染直接读 _specifiers ivar(18.2 dump 实锤), 只 return 不写 ivar = 空白页
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
// v0.0.87: 继承 PSTableCell(假接口+dynamic_lookup, 与 PSListController 同模式) —
// iOS17 AppearanceProvider 渲染 cell 前调 +cellStyle 等类方法协议(13:19 真机崩溃实锤),
// 纯 UITableViewCell 子类缺协议必崩; PSTableCell 子类全套继承。
@interface PSTableCell : UITableViewCell
@end

@interface HNPSliderCell : PSTableCell
@end

@implementation HNPSliderCell {
    UISlider *_slider;
    UILabel *_label;
    NSString *_key;
}

// v0.0.87: 官方渲染入口(cellForSpecifier → initWithStyle:reuseIdentifier:specifier:, 18.2 dump 实锤)
- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)rid specifier:(PSSpecifier *)spec {
    self = [super initWithStyle:style reuseIdentifier:rid];
    if (self) [self buildWithSpecifier:spec];
    return self;
}

// v0.0.87 兜底: 老路径 init(specifier 可能尚未设置, 只出容器)
- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)rid {
    return [super initWithStyle:style reuseIdentifier:rid];
}

- (void)buildWithSpecifier:(PSSpecifier *)spec {
    if (!spec || _slider) return;
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

// v0.0.87: PSTableCell 协议 — 显式给出(与父类一致, 防 17.0 差异)
+ (NSInteger)cellStyle {
    return 1;
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
    // 左侧留给 PSTableCell 默认渲染的名称文本, 滑条+数值占右侧 55%
    CGFloat sliderX = w * 0.42;
    _label.frame = CGRectMake(w - 66.0, 0, 56.0, h);
    _slider.frame = CGRectMake(sliderX, (h - 31.0) / 2.0, w - 66.0 - sliderX - 10.0, 31.0);
}

@end

// ---- 列表控制器(编译期子类, 镜像信息正确) ----
static Class HNPValCellClass(void) { return [HNPSliderCell class]; }

@interface HNPListController : PSListController
@end

@implementation HNPListController {
    NSArray *_specs;
}

// v0.0.87: reloadSpecifiers 会把 _specifiers ivar 清空再调 [self specifiers](18.2 dump 实锤),
// 缓存命中路径必须检测并补写回, 否则 Settings 从后台恢复时页面空白。
static Ivar HNPSpecIvar(void) {
    static Ivar iv;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        iv = class_getInstanceVariable(NSClassFromString(@"PSListController"), "_specifiers");
    });
    return iv;
}

// ---- 开关的自定义读写(target:self) ----
- (NSNumber *)swipeHideForSpecifier:(PSSpecifier *)spec {
    Boolean ok = NO;
    BOOL v = CFPreferencesGetAppBooleanValue(CFSTR("swipeHide"), (__bridge CFStringRef)HNPDomain, &ok);
    if (!ok) v = YES;   // 无配置默认开
    return @(v);
}

- (void)setSwipeHide:(NSNumber *)val forSpecifier:(PSSpecifier *)spec {
    BOOL v = val.boolValue;
    CFPreferencesSetAppValue(CFSTR("swipeHide"), (__bridge CFTypeRef)@(v), (__bridge CFStringRef)HNPDomain);
    HNPPostPrefsChanged();   // 主 tweak darwin 回调 → 关=立即恢复隐藏卡
    HNPPrefsLog([NSString stringWithFormat:@"锁屏左滑隐藏=%@ (已写 CFPreferences+通知)", v ? @"开" : @"关"]);
}

// v0.1.51: 罩层透明模式开关(与 swipeHide 同模式: target+自定义读写)
- (NSNumber *)coverModeForSpecifier:(PSSpecifier *)spec {
    Boolean ok = NO;
    BOOL v = CFPreferencesGetAppBooleanValue(CFSTR("coverMode"), (__bridge CFStringRef)HNPDomain, &ok);
    if (!ok) v = YES;   // 无配置默认开(与 tweak 侧 HNPMCoverMode 默认一致)
    return @(v);
}

- (void)setCoverMode:(NSNumber *)val forSpecifier:(PSSpecifier *)spec {
    BOOL v = val.boolValue;
    CFPreferencesSetAppValue(CFSTR("coverMode"), (__bridge CFTypeRef)@(v), (__bridge CFStringRef)HNPDomain);
    HNPPostPrefsChanged();   // 主 tweak darwin 回调 → HNPMCoverInvalidate 即时生效
    HNPPrefsLog([NSString stringWithFormat:@"罩层透明模式=%@ (已写 CFPreferences+通知)", v ? @"开" : @"关"]);
}

- (NSArray *)specifiers {
    if (_specs) {
        // v0.0.87: reloadSpecifiers 清空 _specifiers ivar 后会再调本方法 — 缓存命中也要补写回
        Ivar iv = HNPSpecIvar();
        id cur = iv ? object_getIvar(self, iv) : nil;
        if (cur != _specs) {
            [self setSpecifiers:_specs];
            HNPPrefsLog(@"v0.0.88 缓存命中 → setSpecifiers 补写回(后台恢复)");
        }
        return _specs;
    }
    _specs = @[];   // v0.0.87: 先占位, 防 setSpecifiers: 内部重入
    [self setTitle:@"HideNowPlaying"];
    NSMutableArray *m = [NSMutableArray array];
    HNPPrefsLog(@"v0.0.88 specifiers 构建: 开始");

    Class PSS = [PSSpecifier class];
    // v0.0.81: 类方法全部运行时存在性检查 — 不存在即降级(不再可能 unrecognized selector 闪退)
    BOOL hasGroup = [PSS respondsToSelector:@selector(groupSpecifierWithName:)];
    BOOL hasPref = [PSS respondsToSelector:@selector(preferenceSpecifierNamed:target:set:get:detail:cell:edit:)];
    HNPPrefsLog([NSString stringWithFormat:@"v0.0.87 方法检查: groupSpecifierWithName=%d preferenceSpecifierNamed=%d", hasGroup, hasPref]);
    if (!hasPref) {
        HNPPrefsLog(@"preferenceSpecifierNamed 不存在 → 返回空页(防崩)");
        [self setSpecifiers:m];
        return m;
    }

    if (hasGroup) {
        PSSpecifier *g1 = [PSS groupSpecifierWithName:nil];
        [g1 setProperty:@"开启后，锁屏音乐卡/实时活动卡支持左滑隐藏并同步隐藏灵动岛；暂停后继续播放会自动恢复显示。关闭后左滑手势不再生效，若已隐藏会立即恢复。"
                 forKey:@"footerText"];
        [m addObject:g1];
    } else {
        PSSpecifier *g1 = [PSS preferenceSpecifierNamed:nil target:nil set:nil get:nil detail:nil cell:0 edit:nil];
        [g1 setProperty:@"开启后，锁屏音乐卡/实时活动卡支持左滑隐藏并同步隐藏灵动岛；暂停后继续播放会自动恢复显示。关闭后左滑手势不再生效，若已隐藏会立即恢复。"
                 forKey:@"footerText"];
        [m addObject:g1];
    }
    HNPPrefsLog(@"v0.0.88 specifiers 构建: group1 完成");

    // v0.0.87: 开关必须 target+自定义读写 — iOS17 PSSwitchCell 在无 get/set 时呈禁用灰态(真机实锤)
    PSSpecifier *sw = [PSS preferenceSpecifierNamed:@"锁屏左滑隐藏"
            target:self set:@selector(setSwipeHide:forSpecifier:) get:@selector(swipeHideForSpecifier:)
            detail:nil cell:6 edit:nil];
    [m addObject:sw];
    HNPPrefsLog(@"v0.0.88 specifiers 构建: 开关完成(target+自定义读写)");

    if (hasGroup) {
        PSSpecifier *g2 = [PSS groupSpecifierWithName:nil];
        [g2 setProperty:@"卡片背景透明度：只淡化白色背景板，文字/封面不受影响。1.0 = 不透明(功能关闭)，0.05 = 接近全透。拖动即时生效。"
                 forKey:@"footerText"];
        [m addObject:g2];
    } else {
        PSSpecifier *g2 = [PSS preferenceSpecifierNamed:nil target:nil set:nil get:nil detail:nil cell:0 edit:nil];
        [g2 setProperty:@"卡片背景透明度：只淡化白色背景板，文字/封面不受影响。1.0 = 不透明(功能关闭)，0.05 = 接近全透。拖动即时生效。"
                 forKey:@"footerText"];
        [m addObject:g2];
    }

    PSSpecifier *sl = [PSS preferenceSpecifierNamed:@"背景透明度"
            target:nil set:nil get:nil detail:nil cell:5 edit:nil];
    [sl setProperty:@0.05 forKey:@"min"];
    [sl setProperty:@1.0 forKey:@"max"];
    [sl setProperty:@0.55 forKey:@"default"];
    [sl setProperty:@"bgAlpha" forKey:@"key"];
    [sl setProperty:HNPDomain forKey:@"defaults"];
    [sl setProperty:HNPValCellClass() forKey:@"cellClass"];
    [m addObject:sl];

    // v0.1.51: 罩层透明模式 — 组页脚 + 开关(代码构建, plist 不参与渲染)
    if (hasGroup) {
        PSSpecifier *g3 = [PSS groupSpecifierWithName:nil];
        [g3 setProperty:@"罩层透明模式：开启后不改写系统材质，改用自建模糊罩层实现透明（更稳定，推荐保持开启）；关闭则回退经典直接改 alpha 方式。原 HideNowPlaying.cover 文件开关已退役。"
                 forKey:@"footerText"];
        [m addObject:g3];
    }
    PSSpecifier *cm = [PSS preferenceSpecifierNamed:@"罩层透明模式"
            target:self set:@selector(setCoverMode:forSpecifier:) get:@selector(coverModeForSpecifier:)
            detail:nil cell:6 edit:nil];
    [m addObject:cm];
    HNPPrefsLog(@"v0.1.51 specifiers 构建: 罩层透明模式开关完成");

    // v0.0.87 核心: 通过官方 setter 写入 _specifiers ivar — 渲染管线读的是这个 ivar,
    // 只 return 不写入 = 上游拿到数组但表格按 nil 渲染 → 空白页
    [self setSpecifiers:m];
    _specs = m;
    HNPPrefsLog(@"v0.0.88 specifiers 构建完成(已 setSpecifiers)");
    return m;
}

@end

__attribute__((constructor))
static void HNPPrefsBundleCtor(void) {
    @autoreleasepool {
        HNPPrefsLog(@"v0.0.88 bundle ctor 进入(编译期子类+防御版)");
    }
}
