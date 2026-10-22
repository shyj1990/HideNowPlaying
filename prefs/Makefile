THEOS_PACKAGE_SCHEME = roothide

TARGET := iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = HideNowPlayingPrefs
HideNowPlayingPrefs_FILES = HNPListController.m
HideNowPlayingPrefs_CFLAGS = -fobjc-arc
HideNowPlayingPrefs_FRAMEWORKS = UIKit Foundation
# Preferences 私有框架(SDK 无 tbd) → undefined dynamic_lookup:
# 链接期放行未定义符号, 运行时 bundle 被加载进 Settings 进程时由
# 已加载的 Preferences.framework 动态解析(PSListController/PSSpecifier)
HideNowPlayingPrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup
HideNowPlayingPrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk
