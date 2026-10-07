// Control Center toggle for CCSupport. Shows BC_STATE and writes the Enabled preference;
// SpringBoard's copy of the tweak does the rest.
//
// The module class is created at runtime and there are no @"" literals or CFSTR on purpose:
// the on-device clang doesn't sign the isa of compiled classes and constant strings, and on
// arm64e SpringBoard dies in objc_msgSend the first time one of those is messaged.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <notify.h>
#include <dlfcn.h>
#include "../names.h"

#define MODULE_NAME "BCToggleModule"
#define STR(s) [NSString stringWithUTF8String:(s)]

// Per-instance state, kept behind the "state" ivar
typedef struct {
	int stateToken;
	int changedToken;
	BOOL registered;
	// What was last asked for, shown until SpringBoard has published it or the request times out
	BOOL pending;
	BOOL pendingValue;
} ModuleState;

static ptrdiff_t stateOffset;

static ModuleState **stateSlot(__unsafe_unretained id self) {
	return (ModuleState **)((char *)(__bridge void *)self + stateOffset);
}

static void refresh(id self) {
	((void (*)(id, SEL))objc_msgSend)(self, sel_registerName("refreshState"));
}

static id moduleInit(id self, SEL _cmd) {
	struct objc_super sup = { self, class_getSuperclass(objc_getClass(MODULE_NAME)) };
	self = ((id (*)(struct objc_super *, SEL))objc_msgSendSuper)(&sup, _cmd);
	if (!self) return nil;
	ModuleState *state = calloc(1, sizeof(ModuleState));
	*stateSlot(self) = state;
	__weak id weakSelf = self;
	state->registered = notify_register_check(BC_STATE, &state->stateToken) == NOTIFY_STATUS_OK;
	if (state->registered && notify_register_dispatch(BC_CHANGED, &state->changedToken, dispatch_get_main_queue(), ^(int token) {
		id strongSelf = weakSelf;
		if (!strongSelf) return;
		(*stateSlot(strongSelf))->pending = NO;
		refresh(strongSelf);
	}) != NOTIFY_STATUS_OK) {
		notify_cancel(state->stateToken);
		state->registered = NO;
	}
	return self;
}

static void moduleDealloc(__unsafe_unretained id self, SEL _cmd) {
	ModuleState *state = *stateSlot(self);
	if (state) {
		if (state->registered) {
			notify_cancel(state->stateToken);
			notify_cancel(state->changedToken);
		}
		free(state);
	}
	struct objc_super sup = { self, class_getSuperclass(objc_getClass(MODULE_NAME)) };
	((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&sup, _cmd);
}

static BOOL moduleIsSelected(id self, SEL _cmd) {
	ModuleState *state = *stateSlot(self);
	if (!state) return NO;
	if (state->pending) return state->pendingValue;
	uint64_t value = 0;
	if (!state->registered || notify_get_state(state->stateToken, &value) != NOTIFY_STATUS_OK) return NO;
	return (value & 1) != 0;
}

static void moduleSetSelected(id self, SEL _cmd, BOOL selected) {
	ModuleState *state = *stateSlot(self);
	if (!state) return;
	state->pending = YES;
	state->pendingValue = selected;
	CFStringRef domain = CFStringCreateWithCString(NULL, BC_DOMAIN, kCFStringEncodingUTF8);
	CFStringRef key = CFStringCreateWithCString(NULL, BC_KEY_ENABLED, kCFStringEncodingUTF8);
	CFPreferencesSetAppValue(key, selected ? kCFBooleanTrue : kCFBooleanFalse, domain);
	CFPreferencesAppSynchronize(domain);
	CFRelease(key);
	CFRelease(domain);
	notify_post(BC_RELOAD);
	refresh(self);
	// Fall back to the real state if nothing gets published (tweak not loaded)
	__weak id weakSelf = self;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
		id strongSelf = weakSelf;
		if (!strongSelf || !(*stateSlot(strongSelf))->pending) return;
		(*stateSlot(strongSelf))->pending = NO;
		refresh(strongSelf);
	});
}

// The original glyph (crossed-out CIA), shipped next to the binary
static UIImage *moduleIconGlyph(id self, SEL _cmd) {
	static UIImage *glyph;
	if (!glyph) {
		Dl_info info;
		if (dladdr((void *)moduleIconGlyph, &info) && info.dli_fname) {
			NSBundle *bundle = [NSBundle bundleWithPath:[STR(info.dli_fname) stringByDeletingLastPathComponent]];
			glyph = [[UIImage imageNamed:STR("Icon") inBundle:bundle compatibleWithTraitCollection:nil] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
		}
	}
	return glyph;
}

static UIColor *moduleSelectedColor(id self, SEL _cmd) {
	return [UIColor systemRedColor];
}

__attribute__((constructor)) static void registerModule(void) {
	Class base = objc_getClass("CCUIToggleModule");
	if (!base || objc_getClass(MODULE_NAME)) return;
	Class cls = objc_allocateClassPair(base, MODULE_NAME, 0);
	if (!cls) return;
	class_addIvar(cls, "state", sizeof(void *), __builtin_ctz(sizeof(void *)), "^v");
	class_addMethod(cls, sel_registerName("init"), (IMP)moduleInit, "@16@0:8");
	class_addMethod(cls, sel_registerName("dealloc"), (IMP)moduleDealloc, "v16@0:8");
	class_addMethod(cls, sel_registerName("isSelected"), (IMP)moduleIsSelected, "B16@0:8");
	class_addMethod(cls, sel_registerName("setSelected:"), (IMP)moduleSetSelected, "v20@0:8B16");
	class_addMethod(cls, sel_registerName("iconGlyph"), (IMP)moduleIconGlyph, "@16@0:8");
	class_addMethod(cls, sel_registerName("selectedColor"), (IMP)moduleSelectedColor, "@16@0:8");
	objc_registerClassPair(cls);
	stateOffset = ivar_getOffset(class_getInstanceVariable(cls, "state"));
}
