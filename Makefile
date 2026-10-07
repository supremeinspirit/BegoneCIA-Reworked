SHELL := /var/jb/bin/sh
VERSION = 1.2.0
# The Control Center module needs the private ControlCenterUIKit stub and headers from Theos
SDK ?= /var/jb/theos/sdks/iPhoneOS16.5.sdk
CCINCLUDE ?= /var/jb/theos/vendor/include
COMMON = -isysroot $(SDK) -O2 -Wall -Wno-four-char-constants
TWEAKFLAGS = $(COMMON) -fno-objc-arc -dynamiclib -framework Foundation -framework CoreFoundation \
	-framework AudioToolbox -framework AVFoundation -framework CoreLocation
MODULEFLAGS = $(COMMON) -I$(CCINCLUDE) -F$(SDK)/System/Library/PrivateFrameworks -fobjc-arc -bundle \
	-framework UIKit -framework Foundation -framework CoreGraphics -framework ControlCenterUIKit
# AltList is linked by path so that it is loaded together with the settings bundle
ALTLIST ?= /var/jb/Library/Frameworks/AltList.framework/AltList
PREFSFLAGS = $(COMMON) -fno-objc-arc -bundle -framework Foundation $(ALTLIST) -rpath /var/jb/Library/Frameworks
# kCFCoreFoundationVersionNumber of iOS 17.0; below it Settings gets the plist-only pane, from it on the bundle
CF_IOS17 = 2000
CLIFLAGS = $(COMMON) -arch arm64 -framework CoreFoundation
SOURCES = Tweak.m ccmodule/BCToggleModule.m ccmodule/Icon.png ccmodule/Icon@2x.png cli.c names.h prefs/BegoneCIA.plist
PREFS_SOURCES = prefs/BCPrefs.m prefs/Root.plist prefs/entry.plist prefs/Info.plist

# $(call build,<output dir>,<arch flags>,<min iOS>)
define build
	mkdir -p $(1)
	clang $(TWEAKFLAGS) $(2) -miphoneos-version-min=$(3) -o $(1)/BegoneCIA.dylib Tweak.m
	clang $(MODULEFLAGS) $(2) -miphoneos-version-min=$(3) -o $(1)/BegoneCIAModule ccmodule/BCToggleModule.m
	clang $(CLIFLAGS) -miphoneos-version-min=$(3) -o $(1)/begonecia cli.c
	ldid -S $(1)/BegoneCIA.dylib && ldid -S $(1)/BegoneCIAModule && ldid -S $(1)/begonecia
endef

# $(call package,<build dir>,<package dir>,<install prefix>)
define package
	rm -rf $(2)
	mkdir -p $(2)/DEBIAN $(2)$(3)/Library/MobileSubstrate/DynamicLibraries $(2)$(3)/Library/PreferenceLoader/Preferences \
		$(2)$(3)/Library/ControlCenter/Bundles/BegoneCIAModule.bundle $(2)$(3)/usr/local/bin
	cp $(1)/BegoneCIA.dylib BegoneCIA.plist $(2)$(3)/Library/MobileSubstrate/DynamicLibraries/
	cp prefs/BegoneCIA.plist prefs/*.png $(2)$(3)/Library/PreferenceLoader/Preferences/
	cp $(1)/BegoneCIAModule ccmodule/Icon.png ccmodule/Icon@2x.png $(2)$(3)/Library/ControlCenter/Bundles/BegoneCIAModule.bundle/
	sed 's/@VERSION@/$(VERSION)/' ccmodule/Info.plist > $(2)$(3)/Library/ControlCenter/Bundles/BegoneCIAModule.bundle/Info.plist
	for i in prefs/BegoneCIA*.png; do cp $$i $(2)$(3)/Library/ControlCenter/Bundles/BegoneCIAModule.bundle/SettingsIcon$${i#prefs/BegoneCIA} || exit 1; done
	cp $(1)/begonecia $(2)$(3)/usr/local/bin/
	cp postinst postrm $(2)/DEBIAN/
	chmod -R 755 $(2) && find $(2) -name '*.plist' -o -name '*.png' | xargs chmod 644
endef

# The rootless package carries two settings panes and PreferenceLoader shows the one that fits the iOS version:
# the plist-only pane (BegoneCIA.plist, as on rootful) below iOS 17, and a bundle that links AltList
# (prefs/Root.plist holds the same items) from iOS 17 on, where Settings fails to load AltList for a plist-only pane.
PL = pkg/var/jb/Library/PreferenceLoader/Preferences
PB = pkg/var/jb/Library/PreferenceBundles/BegoneCIAPrefs.bundle
deb: $(SOURCES) $(PREFS_SOURCES)
	$(call build,build/rootless,-arch arm64 -arch arm64e,15.0)
	clang $(PREFSFLAGS) -arch arm64 -arch arm64e -miphoneos-version-min=15.0 -o build/rootless/BegoneCIAPrefs prefs/BCPrefs.m
	ldid -S build/rootless/BegoneCIAPrefs
	$(call package,build/rootless,pkg,/var/jb)
	# Settings only looks for AltList under /System/Library/PreferenceBundles, and on rootless
	# nothing redirects that for a cell inside the pane, so the bundle is named by its full path
	sed -i -e 's|<key>bundle</key><string>AltList</string>|<key>lazy-bundle</key><string>/var/jb/Library/PreferenceBundles/AltList.bundle</string>|' \
		-e 's|<key>entry</key><dict>|&<key>pl_filter</key><dict><key>CoreFoundationVersion</key><array><real>0</real><real>$(CF_IOS17)</real></array></dict>|' \
		$(PL)/BegoneCIA.plist
	grep -q lazy-bundle $(PL)/BegoneCIA.plist && grep -q pl_filter $(PL)/BegoneCIA.plist
	sed 's|<key>entry</key><dict>|&<key>pl_filter</key><dict><key>CoreFoundationVersion</key><array><real>$(CF_IOS17)</real></array></dict>|' \
		prefs/entry.plist > $(PL)/BegoneCIA17.plist
	grep -q pl_filter $(PL)/BegoneCIA17.plist
	mkdir -p $(PB)
	cp build/rootless/BegoneCIAPrefs prefs/Root.plist prefs/*.png $(PB)/
	sed 's/@VERSION@/$(VERSION)/' prefs/Info.plist > $(PB)/Info.plist
	chmod 755 $(PB) $(PB)/BegoneCIAPrefs && chmod 644 $(PB)/*.plist $(PB)/*.png $(PL)/*.plist
	sed 's/@VERSION@/$(VERSION)/' control > pkg/DEBIAN/control && chmod 644 pkg/DEBIAN/control
	dpkg-deb -Zxz --root-owner-group -b pkg BegoneCIAReworked_$(VERSION)_rootless_iphoneos-arm64.deb

# Rootful iOS 13-14 (arm64 devices; an arm64e slice built here would have the wrong ABI there)
legacy-deb: $(SOURCES)
	$(call build,build/legacy,-arch arm64,13.0)
	$(call package,build/legacy,legacy-pkg,)
	sed -e 's/@VERSION@/$(VERSION)/' -e 's/^Architecture: .*/Architecture: iphoneos-arm/' \
		-e 's/^Depends: .*/Depends: firmware (>= 13.0), firmware (<< 15.0), mobilesubstrate, com.opa334.ccsupport, preferenceloader, com.opa334.altlist/' \
		control > legacy-pkg/DEBIAN/control && chmod 644 legacy-pkg/DEBIAN/control
	dpkg-deb -Zxz --root-owner-group -b legacy-pkg BegoneCIAReworked_$(VERSION)_legacy-rootful_iphoneos-arm.deb

clean:
	rm -rf build pkg legacy-pkg *.deb
