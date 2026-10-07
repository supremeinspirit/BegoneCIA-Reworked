// Names shared by the tweak, the Control Center module and the command line tool.
// Preferences live in the normal CFPreferences domain of user mobile; only SpringBoard reads
// them. Every other process is told the result through notify state, which sandboxed apps
// can read.

// Overridden for the private test build, so it can't touch the live state
#ifndef BC_DOMAIN
#define BC_DOMAIN "me.nepeta.begonecia"
#endif

// Preference keys
#define BC_KEY_ENABLED "Enabled"
#define BC_KEY_PAUSE_CALLS "PauseOnCalls"
#define BC_KEY_PAUSE_FACETIME "PauseOnFaceTime"
#define BC_KEY_EXCLUDED "ExcludedApps"

// Posted after a preference was written; SpringBoard republishes the state
#define BC_RELOAD BC_DOMAIN "/ReloadPrefs"
// Posted by SpringBoard (or an excluded app) after one of the states below changed
#define BC_CHANGED BC_DOMAIN "/Changed"

// 1 while the user has BegoneCIA switched on (what the toggle shows)
#define BC_STATE BC_DOMAIN "/State"
// What is actually enforced: differs from BC_STATE while paused for a call
#define BC_LIVE BC_DOMAIN "/Live"
#define BC_LIVE_ON 1
// Set once SpringBoard has published; without it BC_STATE is used (old SpringBoard still running)
#define BC_LIVE_VALID 2
// pid of the excluded app that is in the foreground, 0 if none. The audio daemons stop
// muting the microphone while it is set.
#define BC_BYPASS BC_DOMAIN "/Bypass"
// BC_EXCLUDED_PREFIX + bundle identifier: 1 while that app is excluded
#define BC_EXCLUDED_PREFIX BC_DOMAIN "/x/"
