SHELL := /var/jb/bin/sh
VERSION = 1.1.1
# The Control Center module needs the private ControlCenterUIKit stub and headers from Theos
SDK ?= /var/jb/theos/sdks/iPhoneOS16.5.sdk
CCINCLUDE ?= /var/jb/theos/vendor/include
COMMON = -isysroot $(SDK) -O2 -Wall -Wno-four-char-constants
TWEAKFLAGS = $(COMMON) -fno-objc-arc -dynamiclib -framework Foundation -framework CoreFoundation \
	-framework AudioToolbox -framework AVFoundation -framework CoreLocation
MODULEFLAGS = $(COMMON) -I$(CCINCLUDE) -F$(SDK)/System/Library/PrivateFrameworks -fobjc-arc -bundle \
	-framework UIKit -framework Foundation -framework ControlCenterUIKit
CLIFLAGS = $(COMMON) -arch arm64 -framework CoreFoundation
SOURCES = Tweak.m ccmodule/BCToggleModule.m ccmodule/Icon.png ccmodule/Icon@2x.png cli.c names.h

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

deb: $(SOURCES)
	$(call build,build/rootless,-arch arm64 -arch arm64e,15.0)
	$(call package,build/rootless,pkg,/var/jb)
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
