#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <X11/Xlib.h>
#import <X11/Xutil.h>
#import <X11/Xatom.h>
#import <X11/extensions/Xcomposite.h>
#import <X11/extensions/shape.h>
#import <unistd.h>
#import <signal.h>
#import <sys/wait.h>
#import <sys/types.h>

// Global display for error handler
static Display *globalDisplay = NULL;
static BOOL suppressErrors = NO;

// X11 error handler
int x11ErrorHandler(Display *dpy, XErrorEvent *err)
{
    if (!suppressErrors) {
        char buf[256];
        XGetErrorText(dpy, err->error_code, buf, sizeof(buf));
        NSLog(@"X11 Error: %s (code %d, request %d)", buf, err->error_code, err->request_code);
    }
    return 0;
}

@interface XEmbedView : NSView
{
    Window containerWindow;
    Display *display;
    Window kateWindow;
    pid_t katePid;
    BOOL embedded;
    NSTimer *windowSearchTimer;
    NSTimer *processMonitorTimer;
    int searchAttempts;
    NSPoint lastPosition;
    NSSize lastSize;
    BOOL isMinimized;
    BOOL isClosing;
    BOOL containerVisible;  // Track container visibility
}
- (id)initWithFrame:(NSRect)frame;
- (void)embedWindow:(Window)window;
- (void)launchKate;
- (Display*)x11Display;
- (Window)kateWindow;
- (void)searchForKateWindow:(NSTimer*)timer;
- (void)setupContainerWindow;
- (void)updateContainerPosition;
- (void)findAndEmbedKateWindow;
- (void)windowIsMoving:(NSNotification *)notification;
- (void)windowIsResizing:(NSNotification *)notification;
- (void)windowDidResize:(NSNotification *)notification;
- (void)windowWillMiniaturize:(NSNotification *)notification;
- (void)windowDidMiniaturize:(NSNotification *)notification;
- (void)windowDidDeminiaturize:(NSNotification *)notification;
- (void)windowDidBecomeKey:(NSNotification *)notification;
- (void)windowDidBecomeMain:(NSNotification *)notification;
- (void)windowDidExpose:(NSNotification *)notification;
- (void)handleWindowRestore;
- (void)restoreKateWindowDelayed:(NSTimer *)timer;
- (void)checkKateProcess:(NSTimer*)timer;
- (void)terminateKate;
- (void)handleKateWindowDestroyed;
- (void)showContainer;  // New method
- (void)hideContainer;  // New method
@end

@implementation XEmbedView

- (id)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        embedded = NO;
        searchAttempts = 0;
        kateWindow = 0;
        katePid = 0;
        isMinimized = NO;
        isClosing = NO;
        containerVisible = NO;  // Start with container hidden
        lastPosition = NSMakePoint(-1, -1);
        lastSize = NSMakeSize(0, 0);
        
        display = XOpenDisplay(NULL);
        if (!display) {
            NSLog(@"Failed to open X display");
            return nil;
        }
        
        globalDisplay = display;
        XSetErrorHandler(x11ErrorHandler);
        
        // Enable composite extension if available
        int event_base, error_base;
        if (XCompositeQueryExtension(display, &event_base, &error_base)) {
            int major = 0, minor = 2;
            XCompositeQueryVersion(display, &major, &minor);
            NSLog(@"Composite extension available: %d.%d", major, minor);
        }
        
        [self setupContainerWindow];
    }
    return self;
}

- (Window)kateWindow
{
    return kateWindow;
}

- (void)showContainer
{
    if (!containerVisible && containerWindow) {
        containerVisible = YES;
        XMapWindow(display, containerWindow);
        XRaiseWindow(display, containerWindow);
        XFlush(display);
        NSLog(@"Container window shown");
    }
}

- (void)hideContainer
{
    if (containerVisible && containerWindow) {
        containerVisible = NO;
        XUnmapWindow(display, containerWindow);
        XFlush(display);
        NSLog(@"Container window hidden");
    }
}

- (void)viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    
    if ([self window]) {
        // Register for window close notification
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(windowWillClose:)
                                                     name:NSWindowWillCloseNotification
                                                   object:[self window]];
        
        // Register for live window movement notifications
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(windowIsMoving:)
                                                     name:NSWindowDidMoveNotification
                                                   object:[self window]];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(windowDidResize:)
                                                     name:NSWindowDidResizeNotification
                                                   object:[self window]];
        
        // Also listen for live resize
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(windowIsResizing:)
                                                     name:NSWindowDidUpdateNotification
                                                   object:[self window]];
        
        // Listen for miniaturization events
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(windowWillMiniaturize:)
                                                     name:NSWindowWillMiniaturizeNotification
                                                   object:[self window]];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(windowDidMiniaturize:)
                                                     name:NSWindowDidMiniaturizeNotification
                                                   object:[self window]];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(windowDidDeminiaturize:)
                                                     name:NSWindowDidDeminiaturizeNotification
                                                   object:[self window]];
        
        // Also listen for window becoming key/main (might fire on restore)
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(windowDidBecomeKey:)
                                                     name:NSWindowDidBecomeKeyNotification
                                                   object:[self window]];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(windowDidBecomeMain:)
                                                     name:NSWindowDidBecomeMainNotification
                                                   object:[self window]];
        
        // Listen for window order changes
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(windowDidExpose:)
                                                     name:NSWindowDidExposeNotification
                                                   object:[self window]];
    }
}

- (void)windowWillClose:(NSNotification *)notification
{
    if (!isClosing) {
        isClosing = YES;
        NSLog(@"Window will close - terminating our Kate instance (PID %d)", katePid);
        
        // Hide container immediately before terminating Kate
        [self hideContainer];
        
        [self terminateKate];
    }
}

- (void)handleKateWindowDestroyed
{
    if (!isClosing) {
        isClosing = YES;
        NSLog(@"Kate window was destroyed - closing wrapper");
        
        // Hide container immediately
        [self hideContainer];
        
        // Stop monitoring timers
        if (processMonitorTimer) {
            [processMonitorTimer invalidate];
            [processMonitorTimer release];
            processMonitorTimer = nil;
        }
        
        if (windowSearchTimer) {
            [windowSearchTimer invalidate];
            [windowSearchTimer release];
            windowSearchTimer = nil;
        }
        
        // Mark as not embedded
        embedded = NO;
        kateWindow = 0;
        katePid = 0;
        
        // Close the wrapper window on the main thread
        [[self window] performSelectorOnMainThread:@selector(performClose:)
                                         withObject:nil
                                      waitUntilDone:NO];
    }
}

- (void)terminateKate
{
    // Stop timers first
    if (windowSearchTimer) {
        [windowSearchTimer invalidate];
        [windowSearchTimer release];
        windowSearchTimer = nil;
    }
    
    if (processMonitorTimer) {
        [processMonitorTimer invalidate];
        [processMonitorTimer release];
        processMonitorTimer = nil;
    }
    
    // Only terminate our specific Kate process
    if (katePid > 0) {
        NSLog(@"Terminating our Kate instance (PID %d)", katePid);
        
        // First check if the process still exists
        if (kill(katePid, 0) != 0) {
            NSLog(@"Kate process %d already terminated", katePid);
            katePid = 0;
            return;
        }
        
        // Send SIGTERM to just our Kate process
        NSLog(@"Sending SIGTERM to Kate process %d", katePid);
        kill(katePid, SIGTERM);
        
        // Give it time to terminate gracefully
        int waitCount = 0;
        while (waitCount < 10) { // Wait up to 1 second
            usleep(100000); // 100ms
            
            // Check if process still exists
            if (kill(katePid, 0) != 0) {
                // Process is gone
                NSLog(@"Kate terminated gracefully");
                break;
            }
            waitCount++;
        }
        
        // If still running, force kill
        if (kill(katePid, 0) == 0) {
            NSLog(@"Kate didn't terminate gracefully, sending SIGKILL to PID %d", katePid);
            kill(katePid, SIGKILL);
        }
        
        // Wait for the process to actually terminate
        int status;
        pid_t result = waitpid(katePid, &status, WNOHANG);
        
        if (result == 0) {
            // Still running somehow, do a blocking wait with timeout
            alarm(2); // Set 2 second timeout
            result = waitpid(katePid, &status, 0);
            alarm(0); // Cancel alarm
        }
        
        if (result > 0) {
            NSLog(@"Kate process %d reaped successfully (status: %d)", katePid, status);
        } else if (result < 0) {
            NSLog(@"Warning: Could not reap Kate process %d: %s", katePid, strerror(errno));
        }
        
        katePid = 0;
    }
}

- (void)windowDidBecomeKey:(NSNotification *)notification
{
    NSLog(@"Window became key - checking if we need to restore");
    if (isMinimized) {
        NSLog(@"Window was minimized, triggering restore");
        [self handleWindowRestore];
    }
}

- (void)windowDidBecomeMain:(NSNotification *)notification
{
    NSLog(@"Window became main - checking if we need to restore");
    if (isMinimized) {
        NSLog(@"Window was minimized, triggering restore");
        [self handleWindowRestore];
    }
}

- (void)windowDidExpose:(NSNotification *)notification
{
    NSLog(@"Window exposed - checking if we need to restore");
    if (isMinimized) {
        NSLog(@"Window was minimized, triggering restore");
        [self handleWindowRestore];
    }
}

- (void)windowIsMoving:(NSNotification *)notification
{
    // Update position immediately during movement
    if (!isMinimized && embedded) {
        [self updateContainerPosition];
    }
}

- (void)windowIsResizing:(NSNotification *)notification
{
    // Update during live resize
    if (!isMinimized && embedded) {
        [self updateContainerPosition];
    }
}

- (void)windowDidResize:(NSNotification *)notification
{
    if (!isMinimized && embedded) {
        [self updateContainerPosition];
    }
}

- (void)windowWillMiniaturize:(NSNotification *)notification
{
    isMinimized = YES;
    
    if (containerWindow) {
        // Just unmap the container - Kate should stay as a child
        XUnmapWindow(display, containerWindow);
        XSync(display, False);
        containerVisible = NO;
        
        NSLog(@"Container window unmapped for minimize");
    }
}

- (void)windowDidMiniaturize:(NSNotification *)notification
{
    isMinimized = YES;
}

- (void)windowDidDeminiaturize:(NSNotification *)notification
{
    NSLog(@"windowDidDeminiaturize called");
    [self handleWindowRestore];
}

- (void)handleWindowRestore
{
    if (!isMinimized) {
        return;  // Already restored
    }
    
    NSLog(@"Starting window restoration");
    
    // Use a timer for the delay
    [NSTimer scheduledTimerWithTimeInterval:0.3
                                      target:self
                                    selector:@selector(restoreKateWindowDelayed:)
                                    userInfo:nil
                                     repeats:NO];
}

- (void)restoreKateWindowDelayed:(NSTimer *)timer
{
    NSLog(@"Restoring Kate window after delay");
    
    isMinimized = NO;
    
    if (containerWindow && embedded) {
        // Check if Kate is still our child
        if (kateWindow) {
            Window root_return, parent_return;
            Window *children_return;
            unsigned int nchildren_return;
            
            if (XQueryTree(display, kateWindow, &root_return, 
                          &parent_return, &children_return, &nchildren_return)) {
                if (children_return) XFree(children_return);
                
                NSLog(@"Kate parent is %lu, our container is %lu", parent_return, containerWindow);
                
                // If Kate is no longer our child, we need to find it again
                if (parent_return != containerWindow) {
                    NSLog(@"Kate detached! Need to re-embed");
                    embedded = NO;
                    [self findAndEmbedKateWindow];
                }
            }
        }
        
        // Update position first
        [self updateContainerPosition];
        
        // Show the container
        [self showContainer];
        
        if (kateWindow && embedded) {
            // Make sure Kate is mapped
            XMapWindow(display, kateWindow);
            XRaiseWindow(display, kateWindow);
            
            // Force Kate to redraw
            NSRect bounds = [self bounds];
            
            // Clear the window to force expose events
            XClearArea(display, kateWindow, 0, 0, 
                      bounds.size.width, bounds.size.height, True);
            
            // Also send an expose event directly
            XEvent exposeEvent;
            memset(&exposeEvent, 0, sizeof(exposeEvent));
            exposeEvent.type = Expose;
            exposeEvent.xexpose.window = kateWindow;
            exposeEvent.xexpose.x = 0;
            exposeEvent.xexpose.y = 0;
            exposeEvent.xexpose.width = bounds.size.width;
            exposeEvent.xexpose.height = bounds.size.height;
            exposeEvent.xexpose.count = 0;
            
            XSendEvent(display, kateWindow, False, ExposureMask, &exposeEvent);
            
            // Set focus
            XSetInputFocus(display, kateWindow, RevertToParent, CurrentTime);
            
            XSync(display, False);
            
            NSLog(@"Kate window should be restored");
        } else {
            NSLog(@"Kate window not embedded, cannot restore");
        }
    }
}

- (void)setupContainerWindow
{
    Window root = DefaultRootWindow(display);
    int screen = DefaultScreen(display);
    
    NSRect frame = [self frame];
    
    // Create window attributes - start without override_redirect
    XSetWindowAttributes attrs;
    memset(&attrs, 0, sizeof(attrs));
    attrs.background_pixel = BlackPixel(display, screen);
    attrs.border_pixel = 0;
    attrs.override_redirect = False;  // Let WM manage initially
    attrs.event_mask = StructureNotifyMask | SubstructureNotifyMask |
                       SubstructureRedirectMask | ExposureMask |
                       PropertyChangeMask | FocusChangeMask |
                       EnterWindowMask | LeaveWindowMask;
    
    // Create the container window
    containerWindow = XCreateWindow(display, root,
                                   0, 0,
                                   frame.size.width, frame.size.height,
                                   0,
                                   CopyFromParent,
                                   InputOutput,
                                   CopyFromParent,
                                   CWBackPixel | CWBorderPixel | CWEventMask,
                                   &attrs);
    
    // Make it frameless
    Atom motifHints = XInternAtom(display, "_MOTIF_WM_HINTS", False);
    if (motifHints != None) {
        struct {
            unsigned long flags;
            unsigned long functions;
            unsigned long decorations;
            long inputMode;
            unsigned long status;
        } hints = {2, 0, 0, 0, 0};  // MWM_HINTS_DECORATIONS = 2, no decorations
        
        XChangeProperty(display, containerWindow, motifHints, motifHints, 32,
                       PropModeReplace, (unsigned char*)&hints, 5);
    }
    
    // Set window type to utility to reduce WM interference
    Atom wmType = XInternAtom(display, "_NET_WM_WINDOW_TYPE", False);
    Atom wmTypeUtility = XInternAtom(display, "_NET_WM_WINDOW_TYPE_UTILITY", False);
    XChangeProperty(display, containerWindow, wmType, XA_ATOM, 32,
                   PropModeReplace, (unsigned char*)&wmTypeUtility, 1);
    
    // Don't show in taskbar or pager
    Atom wmState = XInternAtom(display, "_NET_WM_STATE", False);
    Atom skipTaskbar = XInternAtom(display, "_NET_WM_STATE_SKIP_TASKBAR", False);
    Atom skipPager = XInternAtom(display, "_NET_WM_STATE_SKIP_PAGER", False);
    Atom states[] = {skipTaskbar, skipPager};
    XChangeProperty(display, containerWindow, wmState, XA_ATOM, 32,
                   PropModeReplace, (unsigned char*)states, 2);
    
    // IMPORTANT: Don't map the window here - wait until Kate is embedded
    NSLog(@"Created container window: %lu (initially hidden)", containerWindow);
}

- (void)updateContainerPosition
{
    if (!containerWindow || isMinimized || !embedded) return;
    
    // Get screen position of this view
    NSWindow *window = [self window];
    NSRect frameInWindow = [self convertRect:[self bounds] toView:nil];
    NSRect frameOnScreen = [window convertRectToScreen:frameInWindow];
    
    // Get root window attributes for coordinate conversion
    Window root = DefaultRootWindow(display);
    XWindowAttributes rootAttrs;
    XGetWindowAttributes(display, root, &rootAttrs);
    
    // Convert coordinates (Y is inverted in X11)
    int x = frameOnScreen.origin.x;
    int y = rootAttrs.height - (frameOnScreen.origin.y + frameOnScreen.size.height);
    
    // Use XConfigureWindow for atomic updates
    XWindowChanges changes;
    changes.x = x;
    changes.y = y;
    changes.width = frameOnScreen.size.width;
    changes.height = frameOnScreen.size.height;
    changes.stack_mode = Above;
    
    unsigned int mask = CWX | CWY | CWWidth | CWHeight | CWStackMode;
    
    suppressErrors = YES;
    
    // Move container window smoothly
    XConfigureWindow(display, containerWindow, mask, &changes);
    
    // Update Kate window size if embedded
    if (kateWindow && embedded) {
        changes.x = 0;
        changes.y = 0;
        XConfigureWindow(display, kateWindow, CWX | CWY | CWWidth | CWHeight, &changes);
        // Ensure Kate stays visible
        XMapWindow(display, kateWindow);
    }
    
    // Flush changes immediately for smooth movement
    XFlush(display);
    suppressErrors = NO;
    
    lastPosition = frameOnScreen.origin;
    lastSize = frameOnScreen.size;
}

- (void)drawRect:(NSRect)rect
{
    // Draw a nice background while waiting for Kate
    if (!embedded) {
        // Draw a gradient or solid color instead of pure black
        NSGradient *gradient = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithCalibratedWhite:0.2 alpha:1.0]
                                                              endingColor:[NSColor colorWithCalibratedWhite:0.3 alpha:1.0]];
        [gradient drawInRect:rect angle:90.0];
        [gradient release];
        
        // Draw a loading message
        NSString *loadingText = @"Loading Kate...";
        NSMutableParagraphStyle *style = [[[NSMutableParagraphStyle alloc] init] autorelease];
        [style setAlignment:NSCenterTextAlignment];
        
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:14],
            NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.7 alpha:1.0],
            NSParagraphStyleAttributeName: style
        };
        
        NSSize textSize = [loadingText sizeWithAttributes:attrs];
        NSRect textRect = NSMakeRect(0, (rect.size.height - textSize.height) / 2, 
                                     rect.size.width, textSize.height);
        [loadingText drawInRect:textRect withAttributes:attrs];
    } else {
        // Once embedded, just clear the background
        [[NSColor clearColor] set];
        NSRectFill(rect);
    }
    
    if (!isMinimized && embedded) {
        [self updateContainerPosition];
    } else {
        // Check if window is actually visible (might indicate restore)
        if ([[self window] isVisible] && [[self window] isMiniaturized] == NO) {
            NSLog(@"Window is visible but we think it's minimized - restoring");
            [self handleWindowRestore];
        }
    }
    
    [super drawRect:rect];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    [self hideContainer];  // Hide container before cleanup
    [self terminateKate];
    
    if (display && containerWindow) {
        XDestroyWindow(display, containerWindow);
    }
    if (display) {
        XCloseDisplay(display);
    }
    [super dealloc];
}

- (Display*)x11Display
{
    return display;
}

- (void)launchKate
{
    // Don't show container yet - wait for Kate to be embedded
    // Just update position so it's ready
    [self updateContainerPosition];
    
    katePid = fork();
    if (katePid == 0) {
        // Child process
        
        // Set environment to encourage embedding
        char windowId[32];
        snprintf(windowId, sizeof(windowId), "%lu", containerWindow);
        setenv("WINDOWID", windowId, 1);
        
        // Qt-specific environment variables
        setenv("QT_X11_NO_NATIVE_MENUBAR", "1", 1);
        
        // Disable client-side decorations
        setenv("GTK_CSD", "0", 1);
        setenv("QT_WAYLAND_DISABLE_WINDOWDECORATION", "1", 1);
        
        // Important: Tell Kate to use a specific session to avoid restoring windows
        setenv("KATE_SESSION", "gnustep-wrapper", 1);
        
        // Reset signal handlers to default
        signal(SIGTERM, SIG_DFL);
        signal(SIGINT, SIG_DFL);
        signal(SIGHUP, SIG_DFL);
        
        // Launch Kate with better arguments for embedding
        char *args[] = {
            "kate",
            "-s", "gnustep-wrapper",  // Use a specific session name
            "-b",  // Block - don't detach from terminal
            "--tempfile",  // Start with a temp file instead of restoring session
            NULL
        };
        
        execvp("kate", args);
        
        NSLog(@"Failed to launch Kate: %s", strerror(errno));
        exit(1);
    } else if (katePid < 0) {
        NSLog(@"Failed to fork process");
    } else {
        NSLog(@"Launched Kate with PID: %d", katePid);
        
        // Start searching for Kate's window after a delay
        windowSearchTimer = [[NSTimer scheduledTimerWithTimeInterval:0.1
                                                               target:self
                                                             selector:@selector(searchForKateWindow:)
                                                             userInfo:nil
                                                              repeats:YES] retain];
        
        // Start monitoring Kate process
        processMonitorTimer = [[NSTimer scheduledTimerWithTimeInterval:0.5
                                                                 target:self
                                                               selector:@selector(checkKateProcess:)
                                                               userInfo:nil
                                                                repeats:YES] retain];
    }
}

- (void)checkKateProcess:(NSTimer*)timer
{
    if (katePid <= 0) {
        return;
    }
    
    // Check if Kate process is still running
    if (kill(katePid, 0) != 0) {
        // Process no longer exists
        NSLog(@"Kate process (PID %d) has terminated", katePid);
        
        // Hide container immediately
        [self hideContainer];
        
        // Stop monitoring
        [timer invalidate];
        if (processMonitorTimer == timer) {
            [processMonitorTimer release];
            processMonitorTimer = nil;
        }
        
        katePid = 0;
        embedded = NO;
        kateWindow = 0;
        
        // Close the wrapper window
        if (!isClosing) {
            isClosing = YES;
            [[self window] performClose:nil];
        }
    }
}

- (void)searchForKateWindow:(NSTimer*)timer
{
    if (embedded) {
        [timer invalidate];
        return;
    }
    
    searchAttempts++;
    if (searchAttempts > 100) {
        NSLog(@"Failed to find Kate window after 100 attempts");
        [timer invalidate];
        return;
    }
    
    [self findAndEmbedKateWindow];
}

- (void)findAndEmbedKateWindow
{
    Window root = DefaultRootWindow(display);
    Window parent, *children = NULL;
    unsigned int nchildren;
    
    Atom pidAtom = XInternAtom(display, "_NET_WM_PID", False);
    
    if (XQueryTree(display, root, &root, &parent, &children, &nchildren) != 0) {
        for (unsigned int i = 0; i < nchildren; i++) {
            // Skip our own container window
            if (children[i] == containerWindow) {
                continue;
            }
            
            // Check window PID first
            Atom type;
            int format;
            unsigned long nitems, bytes_after;
            unsigned char *prop = NULL;
            
            if (XGetWindowProperty(display, children[i], pidAtom, 0, 1, False,
                                  XA_CARDINAL, &type, &format, &nitems,
                                  &bytes_after, &prop) == Success && prop) {
                pid_t windowPid = *((pid_t*)prop);
                XFree(prop);
                
                if (windowPid == katePid) {
                    // Check if it's a real window (not a menu or tooltip)
                    XWindowAttributes attrs;
                    if (XGetWindowAttributes(display, children[i], &attrs) &&
                        attrs.map_state != IsUnmapped &&
                        attrs.width > 100 && attrs.height > 100 &&
                        attrs.class == InputOutput) {
                        
                        // Additional check: make sure it's a main window, not a dialog
                        Atom wmWindowType = XInternAtom(display, "_NET_WM_WINDOW_TYPE", False);
                        Atom wmNormalType = XInternAtom(display, "_NET_WM_WINDOW_TYPE_NORMAL", False);
                        Atom actualType;
                        int actualFormat;
                        unsigned long nItems, bytesAfter;
                        unsigned char *windowType = NULL;
                        
                        BOOL isMainWindow = YES;
                        if (XGetWindowProperty(display, children[i], wmWindowType, 0, 1, False,
                                             XA_ATOM, &actualType, &actualFormat, &nItems,
                                             &bytesAfter, &windowType) == Success && windowType) {
                            Atom *typeAtom = (Atom*)windowType;
                            // Only embed normal windows, not dialogs or special windows
                            if (*typeAtom != wmNormalType && *typeAtom != 0) {
                                isMainWindow = NO;
                            }
                            XFree(windowType);
                        }
                        
                        if (isMainWindow) {
                            NSLog(@"Found Kate main window %lu with PID %d", children[i], katePid);
                            [self embedWindow:children[i]];
                            break;
                        }
                    }
                }
            }
        }
        if (children) XFree(children);
    }
}

- (void)embedWindow:(Window)window
{
    if (embedded || window == 0) return;
    
    kateWindow = window;
    NSLog(@"Embedding Kate window %lu into container %lu", kateWindow, containerWindow);
    
    // Grab the server to prevent race conditions
    XGrabServer(display);
    
    // Save the current attributes
    XWindowAttributes attrs;
    XGetWindowAttributes(display, kateWindow, &attrs);
    
    // Select events on Kate window - add DestroyNotify to detect when Kate closes
    XSelectInput(display, kateWindow,
                StructureNotifyMask | PropertyChangeMask | FocusChangeMask | SubstructureNotifyMask);
    
    // Unmap the window first
    XUnmapWindow(display, kateWindow);
    XSync(display, False);
    
    // Remove window manager properties
    Atom wmState = XInternAtom(display, "WM_STATE", False);
    Atom wmNetState = XInternAtom(display, "_NET_WM_STATE", False);
    XDeleteProperty(display, kateWindow, wmState);
    XDeleteProperty(display, kateWindow, wmNetState);
    
    // Don't set override redirect on Kate window - let it cooperate with WM
    XSetWindowAttributes sattr;
    sattr.override_redirect = False;
    XChangeWindowAttributes(display, kateWindow, CWOverrideRedirect, &sattr);
    
    // Reparent Kate window into our container
    XReparentWindow(display, kateWindow, containerWindow, 0, 0);
    
    // Resize to fit container
    NSRect bounds = [self bounds];
    XResizeWindow(display, kateWindow, bounds.size.width, bounds.size.height);
    
    // Map the Kate window
    XMapWindow(display, kateWindow);
    
    // NOW show the container window since Kate is ready
    [self showContainer];
    
    // Raise both windows
    XRaiseWindow(display, containerWindow);
    XRaiseWindow(display, kateWindow);
    
    // Ungrab server
    XUngrabServer(display);
    XSync(display, False);
    
    // Give focus to Kate
    XSetInputFocus(display, kateWindow, RevertToParent, CurrentTime);
    
    // Now set override_redirect on container to make it borderless
    sattr.override_redirect = True;
    XChangeWindowAttributes(display, containerWindow, CWOverrideRedirect, &sattr);
    
    embedded = YES;
    
    // Force a redraw to clear the loading message
    [self setNeedsDisplay:YES];
    
    NSLog(@"Successfully embedded Kate window");
}

- (void)setFrame:(NSRect)frame
{
    [super setFrame:frame];
    if (!isMinimized && embedded) {
        [self updateContainerPosition];
    }
}

- (BOOL)acceptsFirstResponder
{
    return YES;
}

- (void)mouseDown:(NSEvent *)event
{
    // Ensure container window is raised and Kate has focus
    if (display && containerWindow && !isMinimized && embedded) {
        suppressErrors = YES;
        
        XRaiseWindow(display, containerWindow);
        
        if (kateWindow && embedded) {
            // Check if Kate window is still valid
            XWindowAttributes attrs;
            if (XGetWindowAttributes(display, kateWindow, &attrs)) {
                // Only set focus if window is mapped
                if (attrs.map_state == IsViewable) {
                    XSetInputFocus(display, kateWindow, RevertToParent, CurrentTime);
                }
            }
        }
        
        XFlush(display);
        suppressErrors = NO;
    }
}

@end

@interface KateWrapperController : NSObject <NSApplicationDelegate>
{
    NSWindow *mainWindow;
    XEmbedView *embedView;
    NSTimer *positionUpdateTimer;
    NSTimer *x11EventTimer;
}
@end

@implementation KateWrapperController

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    // Create main window
    NSRect frame = NSMakeRect(100, 100, 900, 700);
    mainWindow = [[NSWindow alloc] initWithContentRect:frame
                                             styleMask:(NSTitledWindowMask |
                                                       NSClosableWindowMask |
                                                       NSMiniaturizableWindowMask |
                                                       NSResizableWindowMask)
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
    
    [mainWindow setTitle:@"Kate - GNUstep Wrapper"];
    [mainWindow setReleasedWhenClosed:NO];
    
    // Create embed view
    embedView = [[XEmbedView alloc] initWithFrame:[[mainWindow contentView] bounds]];
    [embedView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];
    
    [[mainWindow contentView] addSubview:embedView];
    
    // Show window
    [mainWindow makeKeyAndOrderFront:nil];
    
    // Launch Kate after a small delay
    [embedView performSelector:@selector(launchKate) 
                     withObject:nil 
                     afterDelay:0.5];
    
    // Reduce update frequency to improve performance
    positionUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:0.03
                                                            target:embedView
                                                          selector:@selector(updateContainerPosition)
                                                          userInfo:nil
                                                           repeats:YES];
    
    // Set up X11 event processing with higher frequency for better responsiveness
    [self setupX11EventProcessing];
}

- (void)setupX11EventProcessing
{
    x11EventTimer = [NSTimer scheduledTimerWithTimeInterval:0.01
                                                      target:self
                                                    selector:@selector(processX11Events:)
                                                    userInfo:nil
                                                     repeats:YES];
}

- (void)processX11Events:(NSTimer*)timer
{
    Display *display = [embedView x11Display];
    if (!display) return;
    
    Window kateWin = [embedView kateWindow];
    
    while (XPending(display)) {
        XEvent event;
        XNextEvent(display, &event);
        
        // Check for DestroyNotify events on Kate window
        if (event.type == DestroyNotify) {
            NSLog(@"Received DestroyNotify event for window %lu", event.xdestroywindow.window);
            
            // Check if this is our Kate window
            if (kateWin && event.xdestroywindow.window == kateWin) {
                NSLog(@"Kate window destroyed - closing wrapper");
                [embedView handleKateWindowDestroyed];
                break;
            }
        }
        // Also check for UnmapNotify which might indicate Kate is closing
        else if (event.type == UnmapNotify && kateWin && event.xunmap.window == kateWin) {
            NSLog(@"Kate window unmapped - checking if it's closing");
            
            // Give Kate a moment to destroy the window if it's closing
            usleep(100000);  // 100ms
            
            // Check if the window still exists
            XWindowAttributes attrs;
            suppressErrors = YES;
            if (!XGetWindowAttributes(display, kateWin, &attrs)) {
                // Window no longer exists
                NSLog(@"Kate window no longer exists after unmap - closing wrapper");
                [embedView handleKateWindowDestroyed];
                suppressErrors = NO;
                break;
            }
            suppressErrors = NO;
        }
    }
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    if (positionUpdateTimer) {
        [positionUpdateTimer invalidate];
    }
    if (x11EventTimer) {
        [x11EventTimer invalidate];
    }
    [embedView release];
    [mainWindow release];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app
{
    return YES;
}

@end

int main(int argc, char *argv[])
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    NSApplication *app = [NSApplication sharedApplication];
    KateWrapperController *controller = [[KateWrapperController alloc] init];
    
    [app setDelegate:controller];
    [app run];
    
    [controller release];
    [pool release];
    
    return 0;
}
