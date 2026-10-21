THEOS_PACKAGE_SCHEME = roothide

TARGET := iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = HideNowPlayingPrefs
HideNowPlayingPrefs_FILES = HNPListController.m
HideNowPlayingPrefs_CFLAGS = -fobjc-arc
HideNowPlayingPrefs_FRAMEWORKS = UIKit Foundation
# Preferences 私有框架完全不链接 — 子类经 HNPListController.m 的 constructor 运行时注册
HideNowPlayingPrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk
