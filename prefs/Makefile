THEOS_PACKAGE_SCHEME = roothide

TARGET := iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = HideNowPlayingPrefs
HideNowPlayingPrefs_FILES = HNPListController.m
HideNowPlayingPrefs_CFLAGS = -fobjc-arc
HideNowPlayingPrefs_FRAMEWORKS = UIKit Foundation
# Preferences 为私有框架(SDK 无 tbd) → weak link, 运行时由 Settings 进程内已加载的框架解析
HideNowPlayingPrefs_LDFLAGS = -weak_framework Preferences
HideNowPlayingPrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk
