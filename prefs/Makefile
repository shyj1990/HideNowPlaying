THEOS_PACKAGE_SCHEME = roothide

TARGET := iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = HideNowPlayingPrefs
HideNowPlayingPrefs_FILES = HNPListController.m
HideNowPlayingPrefs_CFLAGS = -fobjc-arc
HideNowPlayingPrefs_FRAMEWORKS = UIKit Foundation
# Preferences 为私有框架(SDK 无 tbd) → 自带 stub 框架目录(stub/Preferences.framework/Preferences 为
# tbd 文本, 仅声明 PSListController 类符号), 链接期提供符号; 运行时由 Settings 进程内已加载的
# Preferences.framework 解析(tbd 的 install-name 指向真机路径)
HideNowPlayingPrefs_LDFLAGS = -F$(PWD)/stub -framework Preferences
HideNowPlayingPrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk
