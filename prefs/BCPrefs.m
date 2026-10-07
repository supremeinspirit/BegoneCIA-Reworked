// Settings pane. All it does is show Root.plist; it exists as a bundle because it links AltList,
// so the app list controller named in Root.plist is already loaded when the pane is built.
// Naming AltList as a bundle from a plist-only pane failed to load in Settings on iOS 17.
//
// Runtime-created class and no @"" literals, for the same reason as in the Control Center module.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>

#define CONTROLLER_NAME "BCRootListController"
#define STR(s) [NSString stringWithUTF8String:(s)]

// A runtime-created class belongs to no image, so the default lookup would return the Settings app
static NSBundle *rootBundle(id self, SEL _cmd) {
	Dl_info info;
	if (!dladdr((void *)rootBundle, &info) || !info.dli_fname) return nil;
	return [NSBundle bundleWithPath:[STR(info.dli_fname) stringByDeletingLastPathComponent]];
}

static NSArray *rootSpecifiers(id self, SEL _cmd) {
	Ivar ivar = class_getInstanceVariable(object_getClass(self), "_specifiers");
	if (!ivar) return nil;
	NSArray *specifiers = object_getIvar(self, ivar);
	if (!specifiers) {
		specifiers = ((id (*)(id, SEL, id, id, id))objc_msgSend)(self, sel_registerName("loadSpecifiersFromPlistName:target:bundle:"),
			STR("Root"), self, rootBundle(self, NULL));
		// The superclass releases _specifiers in its dealloc
		object_setIvar(self, ivar, [specifiers retain]);
	}
	return specifiers;
}

__attribute__((constructor)) static void registerController(void) {
	Class base = objc_getClass("PSListController");
	if (!base || objc_getClass(CONTROLLER_NAME)) return;
	Class cls = objc_allocateClassPair(base, CONTROLLER_NAME, 0);
	if (!cls) return;
	class_addMethod(cls, sel_registerName("specifiers"), (IMP)rootSpecifiers, "@16@0:8");
	class_addMethod(cls, sel_registerName("bundle"), (IMP)rootBundle, "@16@0:8");
	objc_registerClassPair(cls);
}
