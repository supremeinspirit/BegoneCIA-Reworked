// Control Center module for CCSupport. A tap switches BegoneCIA on and off; a long press or
// 3D Touch expands it to two round buttons, like the connectivity module: that switch and
// "Force" (block in excluded apps and during calls too). It shows BC_STATE and writes the
// preferences; SpringBoard's copy of the tweak does the rest.
//
// The classes are created at runtime and there are no @"" literals or CFSTR on purpose:
// the on-device clang doesn't sign the isa of compiled classes and constant strings, and on
// arm64e SpringBoard dies in objc_msgSend the first time one of those is messaged. Block
// literals have the same problem, so no block goes to an Objective-C method in here.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <notify.h>
#include <dlfcn.h>
#include "../names.h"

#define MODULE_NAME "BCToggleModule"
#define CONTROLLER_NAME "BCExpandingViewController"
#define STR(s) [NSString stringWithUTF8String:(s)]
#define STATE_MASK (BC_STATE_ON | BC_STATE_FORCE)

// Per-controller state, kept behind the "state" ivar
typedef struct {
	int stateToken;
	int changedToken;
	BOOL registered;
	// What was last asked for, shown until SpringBoard has published it or the request times out
	BOOL pending;
	uint64_t pendingValue;
} ModuleState;

static ptrdiff_t stateOffset;
static char controllerKey, containerKey, enabledButtonKey, forceButtonKey;

// Size of the expanded module, and of the area each round button with its labels gets
#define EXPANDED_WIDTH 250.0
#define EXPANDED_HEIGHT 170.0

static void refresh(id self);

static ModuleState *moduleState(__unsafe_unretained id self) {
	ModuleState **slot = (ModuleState **)((char *)(__bridge void *)self + stateOffset);
	if (*slot) return *slot;
	ModuleState *state = calloc(1, sizeof(ModuleState));
	*slot = state;
	__weak id weakSelf = self;
	state->registered = notify_register_check(BC_STATE, &state->stateToken) == NOTIFY_STATUS_OK;
	if (state->registered && notify_register_dispatch(BC_CHANGED, &state->changedToken, dispatch_get_main_queue(), ^(int token) {
		id strongSelf = weakSelf;
		if (!strongSelf) return;
		moduleState(strongSelf)->pending = NO;
		refresh(strongSelf);
	}) != NOTIFY_STATUS_OK) {
		notify_cancel(state->stateToken);
		state->registered = NO;
	}
	return state;
}

static void controllerDealloc(__unsafe_unretained id self, SEL _cmd) {
	ModuleState *state = *(ModuleState **)((char *)(__bridge void *)self + stateOffset);
	if (state) {
		if (state->registered) {
			notify_cancel(state->stateToken);
			notify_cancel(state->changedToken);
		}
		free(state);
	}
	struct objc_super sup = { self, class_getSuperclass(objc_getClass(CONTROLLER_NAME)) };
	((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&sup, _cmd);
}

// BC_STATE_ON and BC_STATE_FORCE as the toggle should show them
static uint64_t shownState(id self) {
	ModuleState *state = moduleState(self);
	if (state->pending) return state->pendingValue;
	uint64_t value = 0;
	if (!state->registered || notify_get_state(state->stateToken, &value) != NOTIFY_STATUS_OK) return 0;
	return value & STATE_MASK;
}

static void setPreference(const char *name, BOOL value, CFStringRef domain) {
	CFStringRef key = CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8);
	CFPreferencesSetAppValue(key, value ? kCFBooleanTrue : kCFBooleanFalse, domain);
	CFRelease(key);
}

static void requestState(id self, uint64_t value) {
	ModuleState *state = moduleState(self);
	state->pending = YES;
	state->pendingValue = value;
	CFStringRef domain = CFStringCreateWithCString(NULL, BC_DOMAIN, kCFStringEncodingUTF8);
	setPreference(BC_KEY_ENABLED, (value & BC_STATE_ON) != 0, domain);
	setPreference(BC_KEY_FORCE, (value & BC_STATE_FORCE) != 0, domain);
	CFPreferencesAppSynchronize(domain);
	CFRelease(domain);
	notify_post(BC_RELOAD);
	refresh(self);
	// Fall back to the real state if nothing gets published (tweak not loaded)
	__weak id weakSelf = self;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
		id strongSelf = weakSelf;
		if (!strongSelf || !moduleState(strongSelf)->pending) return;
		moduleState(strongSelf)->pending = NO;
		refresh(strongSelf);
	});
}

// The two switches are independent: Force is kept while BegoneCIA is off and counts again
// as soon as it is switched back on
static void toggleEnabled(id self) {
	requestState(self, shownState(self) ^ BC_STATE_ON);
}

static void toggleForce(id self) {
	requestState(self, shownState(self) ^ BC_STATE_FORCE);
}

static void showButton(id self, const void *key, BOOL on) {
	id button = objc_getAssociatedObject(self, key);
	((void (*)(id, SEL, BOOL))objc_msgSend)(button, sel_registerName("setEnabled:"), on);
	((void (*)(id, SEL, id))objc_msgSend)(button, sel_registerName("setSubtitle:"), STR(on ? "On" : "Off"));
}

static void refresh(id self) {
	if (![(UIViewController *)self isViewLoaded]) return;
	uint64_t state = shownState(self);
	BOOL on = (state & BC_STATE_ON) != 0, force = (state & BC_STATE_FORCE) != 0;
	((void (*)(id, SEL, id))objc_msgSend)(self, sel_registerName("setSelectedGlyphColor:"), force ? [UIColor systemPurpleColor] : [UIColor systemRedColor]);
	((void (*)(id, SEL, BOOL))objc_msgSend)(self, sel_registerName("setSelected:"), on);
	showButton(self, &enabledButtonKey, on);
	showButton(self, &forceButtonKey, force);
}

// The original glyph (crossed-out CIA), shipped next to the binary
static UIImage *iconGlyph(void) {
	static UIImage *glyph;
	if (!glyph) {
		Dl_info info;
		if (dladdr((void *)iconGlyph, &info) && info.dli_fname) {
			NSBundle *bundle = [NSBundle bundleWithPath:[STR(info.dli_fname) stringByDeletingLastPathComponent]];
			glyph = [[UIImage imageNamed:STR("Icon") inBundle:bundle compatibleWithTraitCollection:nil] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
		}
	}
	return glyph;
}

static UIImage *forceGlyph(void) {
	UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightMedium];
	UIImage *glyph = [UIImage systemImageNamed:STR("lock.shield.fill") withConfiguration:configuration];
	if (!glyph) glyph = [UIImage systemImageNamed:STR("lock.fill") withConfiguration:configuration];
	return [glyph imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

// One round button with its labels, as in the expanded connectivity module
static void addRoundButton(UIViewController *self, UIView *container, const void *key, UIImage *glyph, UIColor *color, const char *title, SEL action) {
	Class buttonClass = objc_getClass("CCUILabeledRoundButtonViewController");
	SEL init = sel_registerName("initWithGlyphImage:highlightColor:useLightStyle:");
	if (!buttonClass || ![buttonClass instancesRespondToSelector:init]) return;
	// Private Control Center classes on three iOS versions: if one of them refuses, the module
	// stays a plain switch instead of taking SpringBoard down
	@try {
		UIViewController *button = ((id (*)(id, SEL, id, id, BOOL))objc_msgSend)([buttonClass alloc], init, glyph, color, YES);
		if (!button) return;
		((void (*)(id, SEL, id))objc_msgSend)(button, sel_registerName("setTitle:"), STR(title));
		((void (*)(id, SEL, BOOL))objc_msgSend)(button, sel_registerName("setLabelsVisible:"), YES);
		// The state comes from what SpringBoard publishes, not from the tap itself
		SEL toggles = sel_registerName("setToggleStateOnTap:");
		if ([button respondsToSelector:toggles]) ((void (*)(id, SEL, BOOL))objc_msgSend)(button, toggles, NO);
		UIView *view = button.view;
		UIControl *control = ((id (*)(id, SEL))objc_msgSend)(button, sel_registerName("button"));
		if (![control isKindOfClass:[UIControl class]]) return;
		[control addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
		[self addChildViewController:button];
		[container addSubview:view];
		[button didMoveToParentViewController:self];
		objc_setAssociatedObject(self, key, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	} @catch (id exception) {
	}
}

// Collapsed: the module's own button. Expanded: the two round buttons instead.
static void showExpanded(id self, BOOL expanded) {
	UIView *container = objc_getAssociatedObject(self, &containerKey);
	container.hidden = !expanded;
	SEL buttonView = sel_registerName("buttonView");
	if ([self respondsToSelector:buttonView]) [((UIView *(*)(id, SEL))objc_msgSend)(self, buttonView) setHidden:expanded];
}

static void controllerViewDidLoad(UIViewController *self, SEL _cmd) {
	struct objc_super sup = { self, class_getSuperclass(objc_getClass(CONTROLLER_NAME)) };
	((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&sup, _cmd);
	((void (*)(id, SEL, id))objc_msgSend)(self, sel_registerName("setGlyphImage:"), iconGlyph());
	UIView *container = [[UIView alloc] initWithFrame:self.view.bounds];
	container.hidden = YES;
	[self.view addSubview:container];
	objc_setAssociatedObject(self, &containerKey, container, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	addRoundButton(self, container, &enabledButtonKey, iconGlyph(), [UIColor systemRedColor], "BegoneCIA", sel_registerName("bcEnabledTapped:"));
	addRoundButton(self, container, &forceButtonKey, forceGlyph(), [UIColor systemPurpleColor], "Force", sel_registerName("bcForceTapped:"));
	refresh(self);
}

static void layoutRoundButton(id self, const void *key, CGRect area) {
	UIView *view = [(UIViewController *)objc_getAssociatedObject(self, key) view];
	// Full width of its area, so the labels have room; the view centres the button itself
	CGFloat height = [view sizeThatFits:area.size].height;
	if (height <= 0 || height > area.size.height) height = area.size.height;
	view.frame = CGRectMake(area.origin.x, round(CGRectGetMidY(area) - height / 2), area.size.width, height);
}

static void controllerViewWillLayoutSubviews(UIViewController *self, SEL _cmd) {
	struct objc_super sup = { self, class_getSuperclass(objc_getClass(CONTROLLER_NAME)) };
	((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&sup, _cmd);
	UIView *container = objc_getAssociatedObject(self, &containerKey);
	CGRect bounds = self.view.bounds;
	container.frame = bounds;
	CGRect left, right;
	CGRectDivide(bounds, &left, &right, bounds.size.width / 2, CGRectMinXEdge);
	layoutRoundButton(self, &enabledButtonKey, left);
	layoutRoundButton(self, &forceButtonKey, right);
}

static CGFloat controllerExpandedHeight(id self, SEL _cmd) {
	return EXPANDED_HEIGHT;
}

static CGFloat controllerExpandedWidth(id self, SEL _cmd) {
	return EXPANDED_WIDTH;
}

static BOOL controllerShouldExpand(id self, SEL _cmd) {
	return objc_getAssociatedObject(self, &enabledButtonKey) && objc_getAssociatedObject(self, &forceButtonKey);
}

static void controllerWillTransition(id self, SEL _cmd, BOOL expanded) {
	if (expanded && !controllerShouldExpand(self, NULL)) expanded = NO;
	Class base = class_getSuperclass(objc_getClass(CONTROLLER_NAME));
	if ([base instancesRespondToSelector:_cmd]) {
		struct objc_super sup = { self, base };
		((void (*)(struct objc_super *, SEL, BOOL))objc_msgSendSuper)(&sup, _cmd, expanded);
	}
	showExpanded(self, expanded);
	if (expanded) refresh(self);
}

// A tap on the collapsed module stays the plain switch
static void controllerButtonTapped(id self, SEL _cmd, id button, id event) {
	toggleEnabled(self);
}

static void controllerEnabledTapped(id self, SEL _cmd, id sender) {
	toggleEnabled(self);
}

static void controllerForceTapped(id self, SEL _cmd, id sender) {
	toggleForce(self);
}

static id moduleContentViewController(id self, SEL _cmd) {
	id controller = objc_getAssociatedObject(self, &controllerKey);
	if (!controller) {
		controller = [[objc_getClass(CONTROLLER_NAME) alloc] init];
		objc_setAssociatedObject(self, &controllerKey, controller, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}
	return controller;
}

// Passed on in case the controller's superclass wants it
static void moduleSetContentModuleContext(id self, SEL _cmd, id context) {
	id controller = moduleContentViewController(self, NULL);
	SEL setter = sel_registerName("setContentModuleContext:");
	if ([controller respondsToSelector:setter]) ((void (*)(id, SEL, id))objc_msgSend)(controller, setter, context);
}

__attribute__((constructor)) static void registerModule(void) {
	Class base = objc_getClass("CCUIButtonModuleViewController");
	if (!base || objc_getClass(CONTROLLER_NAME) || objc_getClass(MODULE_NAME)) return;
	Class controller = objc_allocateClassPair(base, CONTROLLER_NAME, 0);
	if (!controller) return;
	class_addIvar(controller, "state", sizeof(void *), __builtin_ctz(sizeof(void *)), "^v");
	class_addMethod(controller, sel_registerName("dealloc"), (IMP)controllerDealloc, "v16@0:8");
	class_addMethod(controller, sel_registerName("viewDidLoad"), (IMP)controllerViewDidLoad, "v16@0:8");
	class_addMethod(controller, sel_registerName("viewWillLayoutSubviews"), (IMP)controllerViewWillLayoutSubviews, "v16@0:8");
	class_addMethod(controller, sel_registerName("preferredExpandedContentHeight"), (IMP)controllerExpandedHeight, "d16@0:8");
	class_addMethod(controller, sel_registerName("preferredExpandedContentWidth"), (IMP)controllerExpandedWidth, "d16@0:8");
	class_addMethod(controller, sel_registerName("shouldBeginTransitionToExpandedContentModule"), (IMP)controllerShouldExpand, "B16@0:8");
	class_addMethod(controller, sel_registerName("willTransitionToExpandedContentMode:"), (IMP)controllerWillTransition, "v20@0:8B16");
	class_addMethod(controller, sel_registerName("buttonTapped:forEvent:"), (IMP)controllerButtonTapped, "v32@0:8@16@24");
	class_addMethod(controller, sel_registerName("bcEnabledTapped:"), (IMP)controllerEnabledTapped, "v24@0:8@16");
	class_addMethod(controller, sel_registerName("bcForceTapped:"), (IMP)controllerForceTapped, "v24@0:8@16");
	objc_registerClassPair(controller);
	stateOffset = ivar_getOffset(class_getInstanceVariable(controller, "state"));

	Class module = objc_allocateClassPair([NSObject class], MODULE_NAME, 0);
	if (!module) return;
	Protocol *protocol = objc_getProtocol("CCUIContentModule");
	if (protocol) class_addProtocol(module, protocol);
	class_addMethod(module, sel_registerName("contentViewController"), (IMP)moduleContentViewController, "@16@0:8");
	class_addMethod(module, sel_registerName("setContentModuleContext:"), (IMP)moduleSetContentModuleContext, "v24@0:8@16");
	objc_registerClassPair(module);
}
