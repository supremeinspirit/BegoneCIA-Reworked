// BegoneCIA: blocks microphone, camera and location while switched on.
//
// Rewritten after the rootless port 1.0.0 (same hooks), with two additions: apps can be
// excluded, and blocking can pause while a call is active.
//
// SpringBoard is the only process that reads the preferences. It publishes the result as
// notify state (names.h), every other process just reads that state:
//   - an app that is excluded never blocks anything in its own process
//   - the audio daemons, where the microphone is muted for everybody, stop muting while an
//     excluded app is in the foreground (the app announces itself through BC_BYPASS)
//   - during a call SpringBoard publishes "not blocking" if the matching pause switch is on
//   - with "Force" on, SpringBoard publishes no excluded apps and doesn't pause
//
// Written runtime style on purpose: no @implementation, no @"" and no CFSTR. The on-device
// clang doesn't sign the isa of compiled classes and constant strings, and arm64e processes
// die in objc_msgSend the first time one of those is messaged. The same goes for block
// literals: they are fine to call and to hand to C API (dispatch, notify), but must not reach
// anything that sends them -copy, so there are no block-taking Objective-C methods in here.
// Built without ARC so the hooks pass their arguments through untouched.

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <notify.h>
#include <os/lock.h>
#include <dlfcn.h>
#include <signal.h>
#include <errno.h>
#include "names.h"

#define STR(s) [NSString stringWithUTF8String:(s)]

// Overridden for the private test build: a test host can't be called SpringBoard without
// getting every SpringBoard tweak injected
#ifndef SPRINGBOARD_NAME
#define SPRINGBOARD_NAME "SpringBoard"
#endif

// Where the 1.0.0 port (Cephei) kept the switch; read once to carry the setting over
#define OLD_PREFS "/var/jb/var/mobile/Library/Preferences/" BC_DOMAIN ".plist"

static void (*hookFunction)(void *symbol, void *replacement, void **original);
static void (*hookMessage)(Class cls, SEL selector, IMP replacement, IMP *original);

static volatile BOOL blocking;
static BOOL isSpringBoard, isAudioDaemon;
static BOOL selfExcluded, appActive;
static int stateToken = -1, liveToken = -1, bypassToken = -1, selfToken = -1;

static int checkToken(const char *name) {
	int token = -1;
	return notify_register_check(name, &token) == NOTIFY_STATUS_OK ? token : -1;
}

static uint64_t readState(int token) {
	uint64_t value = 0;
	if (token == -1 || notify_get_state(token, &value) != NOTIFY_STATUS_OK) return 0;
	return value;
}

static void refreshBlocking(void) {
	uint64_t live = readState(liveToken);
	BOOL on = (live & BC_LIVE_VALID) ? (live & BC_LIVE_ON) != 0 : (readState(stateToken) & 1) != 0;
	selfExcluded = readState(selfToken) != 0;
	if (selfExcluded) on = NO;
	if (isAudioDaemon && readState(bypassToken) != 0) on = NO;
	blocking = on;
}

#pragma mark - Location

// Managers that got a delegate, and the delegate each one would have without us
static NSHashTable *managers;
static os_unfair_lock managersLock = OS_UNFAIR_LOCK_INIT;
static char delegateKey;

static id (*origManagerInit)(id, SEL, id, id, id, id, id);
static id (*origManagerDelegate)(id, SEL);
static void (*origManagerSetDelegate)(id, SEL, id);
static id (*origManagerLocation)(id, SEL);

// Held weakly, like CLLocationManager's own delegate
static void rememberDelegate(id manager, id delegate) {
	NSHashTable *box = nil;
	// A delegate that is going away can't be referenced weakly, and won't need restoring
	SEL allowsWeak = sel_registerName("allowsWeakReference");
	if (delegate && [delegate respondsToSelector:allowsWeak] && ((BOOL (*)(id, SEL))objc_msgSend)(delegate, allowsWeak)) {
		box = [NSHashTable weakObjectsHashTable];
		[box addObject:delegate];
	}
	objc_setAssociatedObject(manager, &delegateKey, box, OBJC_ASSOCIATION_RETAIN);
	os_unfair_lock_lock(&managersLock);
	[managers addObject:manager];
	os_unfair_lock_unlock(&managersLock);
}

static id rememberedDelegate(id manager) {
	NSHashTable *box = objc_getAssociatedObject(manager, &delegateKey);
	return [[box allObjects] firstObject];
}

static id hookManagerInit(id self, SEL _cmd, id identifier, id path, id website, id delegate, id silo) {
	self = origManagerInit(self, _cmd, identifier, path, website, blocking ? nil : delegate, silo);
	if (self && delegate) rememberDelegate(self, delegate);
	return self;
}

static id hookManagerDelegate(id self, SEL _cmd) {
	return blocking ? nil : origManagerDelegate(self, _cmd);
}

static void hookManagerSetDelegate(id self, SEL _cmd, id delegate) {
	rememberDelegate(self, delegate);
	origManagerSetDelegate(self, _cmd, blocking ? nil : delegate);
}

static id hookManagerLocation(id self, SEL _cmd) {
	return blocking ? nil : origManagerLocation(self, _cmd);
}

#pragma mark - Camera

// Sessions that got inputs, and the inputs each one would have without us
static NSHashTable *sessions;
static os_unfair_lock sessionsLock = OS_UNFAIR_LOCK_INIT;
static char inputsKey;

static void (*origSessionAddInput)(id, SEL, id);
static void (*origSessionRemoveInput)(id, SEL, id);

static NSArray *sessionInputs(id session) {
	return ((NSArray *(*)(id, SEL))objc_msgSend)(session, sel_registerName("inputs"));
}

static void hookSessionAddInput(id self, SEL _cmd, id input) {
	if (input) {
		os_unfair_lock_lock(&sessionsLock);
		NSMutableArray *wanted = objc_getAssociatedObject(self, &inputsKey);
		if (!wanted) {
			wanted = [NSMutableArray arrayWithCapacity:4];
			objc_setAssociatedObject(self, &inputsKey, wanted, OBJC_ASSOCIATION_RETAIN);
		}
		if (![wanted containsObject:input]) [wanted addObject:input];
		[sessions addObject:self];
		os_unfair_lock_unlock(&sessionsLock);
	}
	if (blocking) return;
	origSessionAddInput(self, _cmd, input);
}

static void hookSessionRemoveInput(id self, SEL _cmd, id input) {
	if (input) {
		os_unfair_lock_lock(&sessionsLock);
		[(NSMutableArray *)objc_getAssociatedObject(self, &inputsKey) removeObject:input];
		os_unfair_lock_unlock(&sessionsLock);
	}
	// Already taken out by us
	if (blocking && input && ![sessionInputs(self) containsObject:input]) return;
	origSessionRemoveInput(self, _cmd, input);
}

// Takes the inputs out of a session when blocking starts and puts them back when it ends
static void updateSession(id session) {
	os_unfair_lock_lock(&sessionsLock);
	NSArray *wanted = [[(NSArray *)objc_getAssociatedObject(session, &inputsKey) copy] autorelease];
	os_unfair_lock_unlock(&sessionsLock);
	SEL canAdd = sel_registerName("canAddInput:");
	for (id input in wanted) {
		BOOL present = [sessionInputs(session) containsObject:input];
		if (blocking) {
			if (present) origSessionRemoveInput(session, sel_registerName("removeInput:"), input);
		} else if (!present && ((BOOL (*)(id, SEL, id))objc_msgSend)(session, canAdd, input)) {
			origSessionAddInput(session, sel_registerName("addInput:"), input);
		}
	}
}

// Main thread. Applies a change of `blocking` to the objects that already exist.
static void applyToObjects(void) {
	@autoreleasepool {
		os_unfair_lock_lock(&managersLock);
		NSArray *allManagers = [managers allObjects];
		os_unfair_lock_unlock(&managersLock);
		if (origManagerSetDelegate) {
			for (id manager in allManagers)
				origManagerSetDelegate(manager, sel_registerName("setDelegate:"), blocking ? nil : rememberedDelegate(manager));
		}
		os_unfair_lock_lock(&sessionsLock);
		NSArray *allSessions = [sessions allObjects];
		os_unfair_lock_unlock(&sessionsLock);
		if (origSessionAddInput && origSessionRemoveInput) {
			for (id session in allSessions) updateSession(session);
		}
	}
}

#pragma mark - Microphone

static OSStatus (*origUnitProcess)(AudioUnit, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, AudioBufferList *);
static OSStatus (*origUnitRender)(AudioUnit, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32, AudioBufferList *);
static OSStatus (*origQueueNewInput)(const AudioStreamBasicDescription *, AudioQueueInputCallback, void *, CFRunLoopRef, CFStringRef, UInt32, AudioQueueRef *);
static OSStatus (*origQueueNewInputBlock)(AudioQueueRef *, const AudioStreamBasicDescription *, UInt32, dispatch_queue_t, AudioQueueInputCallbackBlock);
static void (*origVoiceCallback)(id, SEL, id, unsigned long long, id);

static void silence(AudioBufferList *list) {
	for (UInt32 i = 0; i < list->mNumberBuffers; i++) {
		if (list->mBuffers[i].mData) bzero(list->mBuffers[i].mData, list->mBuffers[i].mDataByteSize);
	}
}

static AudioComponentDescription describe(AudioUnit unit) {
	AudioComponentDescription description = {0};
	AudioComponentGetDescription(AudioComponentInstanceGetComponent(unit), &description);
	return description;
}

// In the audio daemons the microphone signal runs through the gain control units
static OSStatus hookUnitProcess(AudioUnit unit, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time, UInt32 frames, AudioBufferList *data) {
	OSStatus status = origUnitProcess(unit, flags, time, frames, data);
	if (blocking && data) {
		OSType subType = describe(unit).componentSubType;
		if (subType == 'agcc' || subType == 'agc2') silence(data);
	}
	return status;
}

// Apps that pull the input bus of the I/O unit themselves
static OSStatus hookUnitRender(AudioUnit unit, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time, UInt32 bus, UInt32 frames, AudioBufferList *data) {
	OSStatus status = origUnitRender(unit, flags, time, bus, frames, data);
	if (bus == 1 && blocking && data) {
		AudioComponentDescription description = describe(unit);
		if (description.componentType == 'auou' && (description.componentSubType == 'vpio' || description.componentSubType == 'rioc')) silence(data);
	}
	return status;
}

// Zeros are only silence in uncompressed audio
static BOOL isPCM(const AudioStreamBasicDescription *format) {
	return format->mFormatID == kAudioFormatLinearPCM;
}

typedef struct {
	AudioQueueInputCallback callback;
	void *userData;
	BOOL pcm;
} QueueContext;

static void queueCallback(void *userData, AudioQueueRef queue, AudioQueueBufferRef buffer, const AudioTimeStamp *time, UInt32 packets, const AudioStreamPacketDescription *descriptions) {
	QueueContext *context = userData;
	if (blocking && context->pcm && buffer && buffer->mAudioData) bzero(buffer->mAudioData, buffer->mAudioDataByteSize);
	context->callback(context->userData, queue, buffer, time, packets, descriptions);
}

static OSStatus hookQueueNewInput(const AudioStreamBasicDescription *format, AudioQueueInputCallback callback, void *userData, CFRunLoopRef runLoop, CFStringRef mode, UInt32 flags, AudioQueueRef *queue) {
	if (!format || !callback) return origQueueNewInput(format, callback, userData, runLoop, mode, flags, queue);
	// Lives as long as the queue; queues are rare enough to not track their disposal
	QueueContext *context = calloc(1, sizeof(QueueContext));
	context->callback = callback;
	context->userData = userData;
	context->pcm = isPCM(format);
	return origQueueNewInput(format, queueCallback, context, runLoop, mode, flags, queue);
}

static OSStatus hookQueueNewInputBlock(AudioQueueRef *queue, const AudioStreamBasicDescription *format, UInt32 flags, dispatch_queue_t dispatchQueue, AudioQueueInputCallbackBlock block) {
	if (!format || !block) return origQueueNewInputBlock(queue, format, flags, dispatchQueue, block);
	BOOL pcm = isPCM(format);
	AudioQueueInputCallbackBlock original = Block_copy(block);
	// Copied to the heap here: that copy is a proper object, the literal isn't (see the top)
	AudioQueueInputCallbackBlock wrapper = Block_copy(^(AudioQueueRef inQueue, AudioQueueBufferRef buffer, const AudioTimeStamp *time, UInt32 packets, const AudioStreamPacketDescription *descriptions) {
		if (blocking && pcm && buffer && buffer->mAudioData) bzero(buffer->mAudioData, buffer->mAudioDataByteSize);
		original(inQueue, buffer, time, packets, descriptions);
	});
	OSStatus status = origQueueNewInputBlock(queue, format, flags, dispatchQueue, wrapper);
	Block_release(wrapper);
	Block_release(original);
	return status;
}

// Siri's recorder in corespeechd
static void hookVoiceCallback(id self, SEL _cmd, id controller, unsigned long long stream, id buffer) {
	static SEL dataSelector, sizeSelector;
	if (!dataSelector) {
		dataSelector = sel_registerName("data");
		sizeSelector = sel_registerName("bytesDataSize");
	}
	if (blocking && buffer) {
		Method data = class_getInstanceMethod(object_getClass(buffer), dataSelector);
		Method size = class_getInstanceMethod(object_getClass(buffer), sizeSelector);
		char type[8] = "";
		if (data) method_getReturnType(data, type, sizeof(type));
		// Only when -data is the raw sample pointer
		if (data && size && type[0] == '^') {
			void *bytes = ((void *(*)(id, SEL))objc_msgSend)(buffer, dataSelector);
			int count = ((int (*)(id, SEL))objc_msgSend)(buffer, sizeSelector);
			if (bytes && count > 0) bzero(bytes, count);
		}
	}
	origVoiceCallback(self, _cmd, controller, stream, buffer);
}

#pragma mark - Excluded app in the foreground

// Main thread. Keeps BC_BYPASS pointing at this app exactly while it is excluded and active.
static void syncBypass(void) {
	if (bypassToken == -1) return;
	uint64_t current = readState(bypassToken);
	uint64_t me = (uint64_t)getpid();
	BOOL want = selfExcluded && appActive;
	if (want == (current == me)) return;
	// Somebody else's entry is theirs to clear
	notify_set_state(bypassToken, want ? me : 0);
	notify_post(BC_CHANGED);
}

// Observes an NSNotification of this process without a block or an observer object
static void observeLocal(const char *name, CFNotificationCallback callback) {
	CFStringRef string = CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8);
	CFNotificationCenterAddObserver(CFNotificationCenterGetLocalCenter(), NULL, callback, string, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
	CFRelease(string);
}

static void appBecameActive(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object, CFDictionaryRef info) {
	appActive = YES;
	syncBypass();
}

static void appEnteredBackground(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object, CFDictionaryRef info) {
	appActive = NO;
	syncBypass();
}

// Both are posted on the main thread
static void observeAppState(void) {
	observeLocal("UIApplicationDidBecomeActiveNotification", appBecameActive);
	observeLocal("UIApplicationDidEnterBackgroundNotification", appEnteredBackground);
}

#pragma mark - SpringBoard

static CFStringRef domain(void) {
	static CFStringRef string;
	if (!string) string = CFStringCreateWithCString(NULL, BC_DOMAIN, kCFStringEncodingUTF8);
	return string;
}

static id preference(const char *key) {
	CFStringRef name = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
	id value = (id)CFPreferencesCopyAppValue(name, domain());
	CFRelease(name);
	return [value autorelease];
}

static BOOL preferenceBool(const char *key) {
	id value = preference(key);
	return [value respondsToSelector:@selector(boolValue)] && [value boolValue];
}

static void migrateOldPreferences(void) {
	if (preference(BC_KEY_ENABLED)) return;
	id old = [[NSDictionary dictionaryWithContentsOfFile:STR(OLD_PREFS)] objectForKey:STR(BC_KEY_ENABLED)];
	if (!old) return;
	CFStringRef key = CFStringCreateWithCString(NULL, BC_KEY_ENABLED, kCFStringEncodingUTF8);
	CFPreferencesSetAppValue(key, (CFPropertyListRef)old, domain());
	CFRelease(key);
	CFPreferencesAppSynchronize(domain());
}

#define CALL_REGULAR 1
#define CALL_FACETIME 2

static BOOL callsObserved;

// Which kinds of calls are ringing or connected right now
static unsigned currentCalls(void) {
	Class centerClass = objc_getClass("TUCallCenter");
	if (!centerClass) return 0;
	id center = ((id (*)(id, SEL))objc_msgSend)(centerClass, sel_registerName("sharedInstance"));
	SEL list = sel_registerName("currentAudioAndVideoCalls");
	if (![center respondsToSelector:list]) list = sel_registerName("currentCalls");
	if (![center respondsToSelector:list]) return 0;
	SEL status = sel_registerName("status"), provider = sel_registerName("provider"), faceTime = sel_registerName("isFaceTimeProvider");
	unsigned kinds = 0;
	for (id call in ((NSArray *(*)(id, SEL))objc_msgSend)(center, list)) {
		if (![call respondsToSelector:status]) continue;
		// TUCallStatus: 1 active, 2 held, 3 sending, 4 ringing, 5 disconnecting, 6 disconnected
		int value = ((int (*)(id, SEL))objc_msgSend)(call, status);
		if (value < 1 || value > 4) continue;
		id callProvider = [call respondsToSelector:provider] ? ((id (*)(id, SEL))objc_msgSend)(call, provider) : nil;
		BOOL isFaceTime = [callProvider respondsToSelector:faceTime] && ((BOOL (*)(id, SEL))objc_msgSend)(callProvider, faceTime);
		kinds |= isFaceTime ? CALL_FACETIME : CALL_REGULAR;
	}
	return kinds;
}

// Bundle identifier -> token of its BC_EXCLUDED_PREFIX name. The tokens stay registered,
// notifyd forgets the state of a name nobody is registered for.
static NSMutableDictionary *excludedTokens;
static NSSet *publishedExcluded;
static uint64_t publishedState = UINT64_MAX, publishedLive = UINT64_MAX;

// Main thread. Reads the preferences and tells everybody if the outcome changed.
static void publish(void) {
	@autoreleasepool {
		CFPreferencesAppSynchronize(domain());
		BOOL enabled = preferenceBool(BC_KEY_ENABLED);
		// Forced: nothing pauses it and no app is excluded
		BOOL forced = enabled && preferenceBool(BC_KEY_FORCE);
		unsigned calls = callsObserved ? currentCalls() : 0;
		BOOL paused = !forced && (((calls & CALL_REGULAR) && preferenceBool(BC_KEY_PAUSE_CALLS)) || ((calls & CALL_FACETIME) && preferenceBool(BC_KEY_PAUSE_FACETIME)));
		uint64_t state = (enabled ? BC_STATE_ON : 0) | (preferenceBool(BC_KEY_FORCE) ? BC_STATE_FORCE : 0);
		uint64_t live = BC_LIVE_VALID | (enabled && !paused ? BC_LIVE_ON : 0);

		NSMutableSet *excluded = [NSMutableSet set];
		id list = forced ? nil : preference(BC_KEY_EXCLUDED);
		if ([list isKindOfClass:[NSArray class]]) {
			for (id identifier in list) {
				if ([identifier isKindOfClass:[NSString class]]) [excluded addObject:identifier];
			}
		}
		if (state == publishedState && live == publishedLive && [excluded isEqualToSet:publishedExcluded]) return;

		for (NSString *identifier in [excludedTokens allKeys]) {
			if (![excluded containsObject:identifier]) notify_set_state([[excludedTokens objectForKey:identifier] intValue], 0);
		}
		for (NSString *identifier in excluded) {
			NSNumber *token = [excludedTokens objectForKey:identifier];
			if (!token) {
				int newToken = checkToken([[STR(BC_EXCLUDED_PREFIX) stringByAppendingString:identifier] UTF8String]);
				if (newToken == -1) continue;
				token = [NSNumber numberWithInt:newToken];
				[excludedTokens setObject:token forKey:identifier];
			}
			notify_set_state([token intValue], 1);
		}
		notify_set_state(stateToken, state);
		notify_set_state(liveToken, live);
		publishedState = state;
		publishedLive = live;
		[publishedExcluded release];
		publishedExcluded = [excluded copy];
		notify_post(BC_CHANGED);
	}
}

static void callStatusChanged(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object, CFDictionaryRef info) {
	dispatch_async(dispatch_get_main_queue(), ^{ publish(); });
	// The call list can lag behind the notification
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ publish(); });
}

static void observeCalls(void) {
	if (!objc_getClass("TUCallCenter")) dlopen("/System/Library/PrivateFrameworks/TelephonyUtilities.framework/TelephonyUtilities", RTLD_LAZY);
	if (!objc_getClass("TUCallCenter")) return;
	callsObserved = YES;
	observeLocal("TUCallCenterCallStatusChangedNotification", callStatusChanged);
	observeLocal("TUCallCenterVideoCallStatusChangedNotification", callStatusChanged);
	publish();
}

// Main thread. An excluded app that dies in the foreground can't clear BC_BYPASS itself.
static void watchBypass(void) {
	static pid_t watched;
	static dispatch_source_t source;
	pid_t pid = (pid_t)readState(bypassToken);
	if (pid == watched) return;
	if (source) {
		dispatch_source_cancel(source);
		dispatch_release(source);
		source = NULL;
	}
	watched = pid;
	if (pid <= 0) return;
	void (^clear)(void) = ^{
		if ((pid_t)readState(bypassToken) != pid) return;
		notify_set_state(bypassToken, 0);
		notify_post(BC_CHANGED);
	};
	if (kill(pid, 0) != 0 && errno == ESRCH) {
		clear();
		return;
	}
	source = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, pid, DISPATCH_PROC_EXIT, dispatch_get_main_queue());
	if (!source) return;
	dispatch_source_set_event_handler(source, clear);
	dispatch_resume(source);
}

#pragma mark - Setup

static void installHooks(void) {
	hookFunction = dlsym(RTLD_DEFAULT, "MSHookFunction");
	hookMessage = dlsym(RTLD_DEFAULT, "MSHookMessageEx");
	if (!hookFunction || !hookMessage) {
		void *substrate = dlopen("/var/jb/usr/lib/libsubstrate.dylib", RTLD_LAZY);
		if (!substrate) substrate = dlopen("/usr/lib/libsubstrate.dylib", RTLD_LAZY);
		if (!substrate) return;
		hookFunction = dlsym(substrate, "MSHookFunction");
		hookMessage = dlsym(substrate, "MSHookMessageEx");
		if (!hookFunction || !hookMessage) return;
	}

	Class manager = objc_getClass("CLLocationManager");
	if (manager) {
		SEL init = sel_registerName("initWithEffectiveBundleIdentifier:bundlePath:websiteIdentifier:delegate:silo:");
		if (class_getInstanceMethod(manager, init)) hookMessage(manager, init, (IMP)hookManagerInit, (IMP *)&origManagerInit);
		hookMessage(manager, sel_registerName("delegate"), (IMP)hookManagerDelegate, (IMP *)&origManagerDelegate);
		hookMessage(manager, sel_registerName("setDelegate:"), (IMP)hookManagerSetDelegate, (IMP *)&origManagerSetDelegate);
		hookMessage(manager, sel_registerName("location"), (IMP)hookManagerLocation, (IMP *)&origManagerLocation);
	}

	Class session = objc_getClass("AVCaptureSession");
	if (session) {
		hookMessage(session, sel_registerName("addInput:"), (IMP)hookSessionAddInput, (IMP *)&origSessionAddInput);
		hookMessage(session, sel_registerName("removeInput:"), (IMP)hookSessionRemoveInput, (IMP *)&origSessionRemoveInput);
	}

	hookFunction((void *)AudioUnitProcess, (void *)hookUnitProcess, (void **)&origUnitProcess);
	hookFunction((void *)AudioUnitRender, (void *)hookUnitRender, (void **)&origUnitRender);
	hookFunction((void *)AudioQueueNewInput, (void *)hookQueueNewInput, (void **)&origQueueNewInput);
	hookFunction((void *)AudioQueueNewInputWithDispatchQueue, (void *)hookQueueNewInputBlock, (void **)&origQueueNewInputBlock);

	Class recorder = objc_getClass("CSAudioRecorder");
	SEL voiceCallback = sel_registerName("voiceControllerAudioCallback:forStream:buffer:");
	if (recorder && !strcmp(getprogname(), "corespeechd") && class_getInstanceMethod(recorder, voiceCallback))
		hookMessage(recorder, voiceCallback, (IMP)hookVoiceCallback, (IMP *)&origVoiceCallback);
}

__attribute__((constructor)) static void setup(void) {
	@autoreleasepool {
		const char *program = getprogname();
		isSpringBoard = !strcmp(program, SPRINGBOARD_NAME);
		static const char *daemons[] = { "mediaserverd", "audiomxd", "corespeechd", "assistantd" };
		for (int i = 0; i < 4; i++) {
			if (!strcmp(program, daemons[i])) isAudioDaemon = YES;
		}

		managers = [[NSHashTable weakObjectsHashTable] retain];
		sessions = [[NSHashTable weakObjectsHashTable] retain];
		stateToken = checkToken(BC_STATE);
		liveToken = checkToken(BC_LIVE);
		bypassToken = checkToken(BC_BYPASS);

		BOOL isApp = NO;
		if (!isSpringBoard && !isAudioDaemon && objc_getClass("UIApplication")) {
			CFStringRef identifier = CFBundleGetIdentifier(CFBundleGetMainBundle());
			char name[512] = BC_EXCLUDED_PREFIX;
			size_t prefix = strlen(name);
			if (identifier && CFStringGetCString(identifier, name + prefix, sizeof(name) - prefix, kCFStringEncodingUTF8)) {
				selfToken = checkToken(name);
				isApp = YES;
			}
		}

		installHooks();

		int token;
		if (isSpringBoard) {
			excludedTokens = [[NSMutableDictionary alloc] init];
			migrateOldPreferences();
			publish();
			refreshBlocking();
			notify_register_dispatch(BC_RELOAD, &token, dispatch_get_main_queue(), ^(int t) { publish(); });
			notify_register_dispatch(BC_CHANGED, &token, dispatch_get_main_queue(), ^(int t) {
				refreshBlocking();
				watchBypass();
				applyToObjects();
			});
			dispatch_async(dispatch_get_main_queue(), ^{ watchBypass(); });
			// The call center isn't ours to wake up during launch
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ observeCalls(); });
			return;
		}

		refreshBlocking();
		if (isApp) observeAppState();
		void (^changed)(int) = ^(int t) {
			refreshBlocking();
			// The daemons have nothing on the main queue to update, and may not even run one
			if (isAudioDaemon) return;
			dispatch_async(dispatch_get_main_queue(), ^{
				if (isApp) syncBypass();
				applyToObjects();
			});
		};
		dispatch_queue_t queue = dispatch_queue_create(BC_DOMAIN, DISPATCH_QUEUE_SERIAL);
		notify_register_dispatch(BC_CHANGED, &token, queue, changed);
		// Still posted by the 1.0.0 toggle while that SpringBoard hasn't been restarted
		notify_register_dispatch(BC_RELOAD, &token, queue, changed);
	}
}
