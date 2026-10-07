// begonecia on|off|toggle|status
// Built arm64 only, so CFSTR is fine here (see the note in Tweak.m).

#include <CoreFoundation/CoreFoundation.h>
#include <notify.h>
#include <stdio.h>
#include <string.h>
#include "names.h"

static uint64_t state(const char *name) {
	int token;
	uint64_t value = 0;
	if (notify_register_check(name, &token) != NOTIFY_STATUS_OK) return 0;
	notify_get_state(token, &value);
	notify_cancel(token);
	return value;
}

int main(int argc, char **argv) {
	if (argc != 2) {
		fprintf(stderr, "usage: begonecia on|off|toggle|status\n");
		return 2;
	}
	bool on = state(BC_STATE) & 1;
	if (!strcmp(argv[1], "status")) {
		uint64_t live = state(BC_LIVE);
		if (!on) puts("off");
		else if ((live & BC_LIVE_VALID) && !(live & BC_LIVE_ON)) puts("on (paused for a call)");
		else puts("on (blocking camera/mic/location)");
		return 0;
	}
	if (!strcmp(argv[1], "on")) on = true;
	else if (!strcmp(argv[1], "off")) on = false;
	else if (!strcmp(argv[1], "toggle")) on = !on;
	else {
		fprintf(stderr, "begonecia: unknown command '%s'\n", argv[1]);
		return 2;
	}
	// The preferences belong to mobile, also when this runs as root
	CFPreferencesSetValue(CFSTR(BC_KEY_ENABLED), on ? kCFBooleanTrue : kCFBooleanFalse, CFSTR(BC_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost);
	if (!CFPreferencesSynchronize(CFSTR(BC_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost)) {
		fprintf(stderr, "begonecia: could not write the preference\n");
		return 1;
	}
	notify_post(BC_RELOAD);
	printf("begonecia %s\n", on ? "on" : "off");
	return 0;
}
