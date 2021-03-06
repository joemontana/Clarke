#import "FirehookApplicationDelegate.h"

#ifdef DEBUG
#define IDLE_TIMEOUT 30
#else
#define IDLE_TIMEOUT 300
#endif

#ifdef DEBUG
#define FIREEAGLE_INTERVAL 10
#else
#define FIREEAGLE_INTERVAL 300
#endif

@interface FirehookApplicationDelegate(Private)

- (void)rescheduleLocationRefreshTimer;
- (NSView *)statusMenuHeaderView;

- (void)configureDefaultSettings;
- (void)doFirstRunIfNeeded;
- (void)tellUserAboutStatusMenu;
- (void)askUserWhetherToStartAtBoot;
- (void)openPreferences;

- (BOOL)shouldPauseUpdatesWhenIdle;

@end


@implementation FirehookApplicationDelegate

@synthesize locationController;

- (id) init {
	self = [super init];
	if (self != nil) {
		
		unsigned major, minor, bugFix;
    [[NSApplication sharedApplication] getSystemVersionMajor:&major minor:&minor bugFix:&bugFix];
		if (major >= 10 && minor >= 6) {
			locationController = [CoreLocationController sharedInstance];
		} else {
			locationController = [SkyhookLocationController sharedInstance];
			locationController.delegate = self;
		}
		
		thePreferencesWindowController = [[PreferencesWindowController alloc] init];
		theStatusHeaderViewController = [[StatusMenuHeaderViewController alloc] init];
		theFireEagleController = [FireEagleController sharedInstance];
	}
	return self;
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	locationController.delegate = nil;
	[thePreferencesWindowController release];
	[theStatusHeaderViewController release];
	[super dealloc];
}

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
	systemIdleTimer = [[RHSystemIdleTimer alloc] initSystemIdleTimerWithTimeInterval:IDLE_TIMEOUT];
	[systemIdleTimer setDelegate:self];
	isIdle = NO;
	
	[self registerURLHandler];
	[self configureDefaultSettings];
	[self activateStatusMenu];
	
	[self doFirstRunIfNeeded];
	
	// register for location updates & fire the first request
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(locationDidChange:) name:UpdatedLocationNotification object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(locationUpdateDidFail:) name:FailedLocationUpdateNotification object:nil];
	[locationController startUpdating];
	
	// register for awake from sleep notifications
	[[[NSWorkspace sharedWorkspace] notificationCenter] addObserver: self 
														   selector: @selector(receiveWakeNote:) 
															   name: NSWorkspaceDidWakeNotification 
															 object: nil];
}

- (void)registerURLHandler {
  NSAppleEventManager *appleEventManager = [NSAppleEventManager sharedAppleEventManager];
  [appleEventManager setEventHandler:self andSelector:@selector(handleGetURLEvent:withReplyEvent:) forEventClass:kInternetEventClass andEventID:kAEGetURL];
}

- (void)configureDefaultSettings {
	[[NSUserDefaults standardUserDefaults] registerDefaults:[NSDictionary dictionaryWithObjectsAndKeys:@"YES", @"pauseUpdatesWhenIdle", nil]];
	
}

- (void)doFirstRunIfNeeded {
	if (![[NSUserDefaults standardUserDefaults] boolForKey:@"firstRunDone"]) {
		[self openPreferences];
		[self tellUserAboutStatusMenu];
		
		[thePreferencesWindowController selectFireEagle:self];
		[[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"firstRunDone"];
	} else if (![[NSUserDefaults standardUserDefaults] boolForKey:@"secondRunDone"]) {
		//[self askUserWhetherToStartAtBoot];
		[[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"secondRunDone"];
	}
}

- (void)tellUserAboutStatusMenu {
	NSAlert *alert = [[NSAlert alloc] init];
	[alert addButtonWithTitle:@"OK"];
	[alert setMessageText:@"Clarke is now running in the system menu"];
	[alert setInformativeText:@"It will attempt to triangulate your position every 5 minutes using nearby wireless access points, and if you sign into Fire Eagle it will update your location there."];
	[alert setAlertStyle:NSInformationalAlertStyle];
	[alert beginSheetModalForWindow:thePreferencesWindowController.window modalDelegate:self didEndSelector:NULL contextInfo:NULL];
	[alert release];
}

- (void)askUserWhetherToStartAtBoot {
	NSAlert *alert = [[NSAlert alloc] init];
	[alert addButtonWithTitle:@"Yes"];
	[alert addButtonWithTitle:@"No"];
	[alert setMessageText:@"Run Clarke automatically when this computer starts up?"];
	[alert setInformativeText:@"You can change this at any time in the preferences."];
	[alert setAlertStyle:NSWarningAlertStyle];
	
	if ([alert runModal] == NSAlertFirstButtonReturn) {
		GeneralPreferencesViewController *g = [[GeneralPreferencesViewController alloc] init];
		[g addMainBundleToLoginItems];
		[g release];
	}
	[alert release];
}

- (void)receiveWakeNote:(NSNotification*)note {
	NSLog(@"Application woke from sleep - refreshing");
	[locationController stopUpdating];
	[locationController startUpdating];
}

- (void)activateStatusMenu {
	NSStatusBar *bar = [NSStatusBar systemStatusBar];
	
	theStatusItem = [bar statusItemWithLength:NSSquareStatusItemLength];
	[theStatusItem retain];
	
	[theStatusItem setImage:[NSImage imageNamed:@"status-bar-icon-ok.png"]];
	[theStatusItem setHighlightMode:YES];
	
	NSMenu *theMenu = [[NSMenu alloc] init];
	[theMenu setDelegate:self];
	[theMenu setAutoenablesItems:NO];
	
	NSMenuItem *statusMenuHeaderItem = [[NSMenuItem alloc] init];
	[statusMenuHeaderItem setView:theStatusHeaderViewController.view];
	[theMenu addItem:statusMenuHeaderItem];
	[statusMenuHeaderItem release];
	
	[theMenu addItem:[NSMenuItem separatorItem]];
	
	nearbyItem = [[NSMenuItem alloc] initWithTitle:@"Nearby" action:NULL keyEquivalent:@""];
	NSMenu *nearbyMenu = [[NSMenu alloc] init];
	[nearbyMenu addItemWithTitle:@"Flickr" action:@selector(openFlickr) keyEquivalent:@""];
	[nearbyMenu addItemWithTitle:@"Google Maps" action:@selector(openGoogleMaps) keyEquivalent:@""];
	[nearbyMenu addItemWithTitle:@"OpenStreetMap" action:@selector(openOpenStreetMap) keyEquivalent:@""];
	[nearbyMenu addItemWithTitle:@"Yahoo Maps" action:@selector(openYahoo) keyEquivalent:@""];
	[nearbyItem setSubmenu:nearbyMenu];
	[theMenu addItem:nearbyItem];
	[nearbyMenu release];
	[nearbyItem release];
	
	if ([locationController lastKnownLocation] == nil) {
		[nearbyItem setEnabled:NO];
	}
	
	NSMenuItem *openPreferencesItem = [[NSMenuItem alloc] initWithTitle:@"Preferences..." action:@selector(openPreferences) keyEquivalent:@","];
	[openPreferencesItem setKeyEquivalentModifierMask:NSCommandKeyMask];
	[theMenu addItem:openPreferencesItem];
	[openPreferencesItem release];
	
	NSMenuItem *quitMenuItem = [[NSMenuItem alloc] initWithTitle:@"Quit" action:@selector(quit) keyEquivalent:@"Q"];
	[quitMenuItem setKeyEquivalentModifierMask:NSCommandKeyMask];
	[theMenu addItem:quitMenuItem];
	[quitMenuItem release];
	
	[theStatusItem setMenu:theMenu];
	[theMenu release];
}

- (void)startFireEagleUpdater {
	if (![fireEagleUpdateTimer isValid] && [theFireEagleController hasAccessToken] && [locationController lastKnownLocation]) {
		if (!([self shouldPauseUpdatesWhenIdle] && isIdle)) {
			[theFireEagleController updateLocation:[locationController lastKnownLocation]];
		}
		[self scheduleFireEagleUpdateTimer];
	}
}

- (void)stopFireEagleUpdater {
	[self killFireEagleUpdateTimer];
}

- (void)locationDidChange:(NSNotification *)notification {
	[nearbyItem setEnabled:YES];
	Location *location = notification.object;
	NSLog(@"Location did change: %@", location);
	[self startFireEagleUpdater];
}

- (void)killFireEagleUpdateTimer {
	[fireEagleUpdateTimer invalidate];
	[fireEagleUpdateTimer release];
	fireEagleUpdateTimer = nil;
}

- (void)scheduleFireEagleUpdateTimer {
	[self killFireEagleUpdateTimer]; // ensure it's not running
	
	NSInteger updateInterval = FIREEAGLE_INTERVAL;
	fireEagleUpdateTimer = [NSTimer timerWithTimeInterval:updateInterval 
																								 target:self 
																							 selector:@selector(fireEagleUpdateTimerDidFire) 
																							 userInfo:nil 
																								repeats:YES];
	[[NSRunLoop currentRunLoop] addTimer:fireEagleUpdateTimer forMode:NSRunLoopCommonModes];
	NSLog(@"Scheduled next Fire Eagle check & update for every %u seconds", FIREEAGLE_INTERVAL);
}

- (void)fireEagleUpdateTimerDidFire {
	NSLog(@"Fire Eagle Update timer fired");
	if ([theFireEagleController hasAccessToken]) {
		if (!([self shouldPauseUpdatesWhenIdle] && isIdle)) {
			NSLog(@"Firing Fire Eagle Controller update.");
			[theFireEagleController updateLocation:[locationController lastKnownLocation]];
		}
	} else {
		[self killFireEagleUpdateTimer];
	}
}	

- (void)locationUpdateDidFail:(NSError *)error {
	//[self rescheduleLocationRefreshTimer];
	[theStatusHeaderViewController configureViewForError:error];
}

- (void)menuWillOpen:(NSMenu *)menu {
	[theStatusHeaderViewController viewWillAppear];
}

- (void)openPreferences {
	[[NSApplication sharedApplication] activateIgnoringOtherApps:YES];
	[thePreferencesWindowController showWindow:self];
}

- (void)openFlickr {
	Location *location = [locationController lastKnownLocation];
	NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://www.flickr.com/nearby/%f,%f", location.coordinate.latitude, location.coordinate.longitude]];
	[[NSWorkspace sharedWorkspace] openURL:url];
}

- (void)openGoogleMaps {
	Location *location = [locationController lastKnownLocation];
	NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://maps.google.com/?q=%f,%f", location.coordinate.latitude, location.coordinate.longitude]];
	[[NSWorkspace sharedWorkspace] openURL:url];
}

- (void)openOpenStreetMap {
	Location *location = [locationController lastKnownLocation];
	NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://www.openstreetmap.org/?lat=%f&lon=%f&zoom=15&layers=B000FTF", location.coordinate.latitude, location.coordinate.longitude]];
	[[NSWorkspace sharedWorkspace] openURL:url];
}

- (void)openYahoo {
	Location *location = [locationController lastKnownLocation];
	NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://maps.yahoo.com/?lat=%f&lon=%f&zoom=16", location.coordinate.latitude, location.coordinate.longitude]];
	[[NSWorkspace sharedWorkspace] openURL:url];
}

- (void)quit {
	[[NSApplication sharedApplication] terminate:self];
}

- (void)timerBeginsIdling:(id)sender {
	NSLog(@"Clarke began idling");
	isIdle = YES;
	
//	if ([self shouldPauseUpdatesWhenIdle]) {
//		[locationController stopUpdating];
//	}
}

- (void)timerFinishedIdling:(id)sender {
	NSLog(@"Clarke awoke from idling");
	isIdle = NO;
	
//	if ([self shouldPauseUpdatesWhenIdle]) {
//		[locationController startUpdating];
//	}
}

- (BOOL)shouldPauseUpdatesWhenIdle {
	return [[NSUserDefaults standardUserDefaults] boolForKey:@"pauseUpdatesWhenIdle"];
}

- (void)handleGetURLEvent:(NSAppleEventDescriptor *)event withReplyEvent:(NSAppleEventDescriptor *)replyEvent
{
	NSString *url = [[event paramDescriptorForKeyword:keyDirectObject] stringValue];
	NSLog(url);
	[[NSApplication sharedApplication] activateIgnoringOtherApps:YES];
	[[thePreferencesWindowController window] orderFrontRegardless];
	[thePreferencesWindowController selectFireEagle:self];
}

@end
