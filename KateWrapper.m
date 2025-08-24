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
    int searchAttempts;
    NSPoint lastPosition;
    NSSize lastSize;
    BOOL isMoving;
}
- (id)initWithFrame:(NSRect)frame;
- (void)embedWindow:(Window)window;
- (void)launchKate;
- (Display*)x11Display;
- (void)searchForKateWindow:(NSTimer*)timer;
- (void)setupContainerWindow;
- (void)updateContainerPosition;
- (void)findAndEmbedKateWindow;
- (void)windowWillMove:(NSNotification *)notification;
- (void)windowDidMove:(NSNotification *)notification;
- (void)windowDidResize:(NSNotification *)notification;
@end

@implementation XEmbedView

- (id)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        embedded = NO;
        searchAttempts = 0;
        kateWindow = 0;
        isMoving = NO;
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

- (void)viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    
    if ([self window]) {
        // Register for window movement notifications
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(windowWillMove:)
                                                     name:NSWindowWillMoveNotification
                                                   object:[self window]];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(windowDidMove:)
                                                     name:NSWindowDidMoveNotification
                                                   object:[self window]];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(windowDidResize:)
                                                     name:NSWindowDidResizeNotification
                                                   object:[self window]];
    }
}

- (void)windowWillMove:(NSNotification *)notification
{
    isMoving = YES;
    // Hide the Kate window during move to prevent ghost window
    if (kateWindow && embedded) {
        XUnmapWindow(display, kateWindow);
        XFlush(display);
    }
}

- (void)windowDidMove:(NSNotification *)notification
{
    isMoving = NO;
    [self updateContainerPosition];
    
    // Remap the Kate window after move
    if (kateWindow && embedded) {
        XMapWindow(display, kateWindow);
        XFlush(display);
    }
}

- (void)windowDidResize:(NSNotification *)notification
{
    [self updateContainerPosition];
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
    
    NSLog(@"Created container window: %lu", containerWindow);
}

- (void)updateContainerPosition
{
    if (!containerWindow || isMoving) return;
    
    // Get screen position of this view
    NSWindow *window = [self window];
    NSRect frameInWindow = [self convertRect:[self bounds] toView:nil];
    NSRect frameOnScreen = [window convertRectToScreen:frameInWindow];
    
    lastPosition = frameOnScreen.origin;
    lastSize = frameOnScreen.size;
    
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
    XConfigureWindow(display, containerWindow, mask, &changes);
    
    // Ensure it's mapped and visible
    XMapRaised(display, containerWindow);
    
    // Update Kate window size if embedded
    if (kateWindow && embedded) {
        changes.x = 0;
        changes.y = 0;
        XConfigureWindow(display, kateWindow, CWX | CWY | CWWidth | CWHeight, &changes);
    }
    
    // Force immediate update
    XSync(display, False);
    suppressErrors = NO;
}

- (void)drawRect:(NSRect)rect
{
    [[NSColor darkGrayColor] set];
    NSRectFill(rect);
    
    if (!isMoving) {
        [self updateContainerPosition];
    }
    
    [super drawRect:rect];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    if (windowSearchTimer) {
        [windowSearchTimer invalidate];
        [windowSearchTimer release];
    }
    if (katePid > 0) {
        kill(katePid, SIGTERM);
        waitpid(katePid, NULL, 0);
    }
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
    // First ensure container is visible and positioned
    [self updateContainerPosition];
    XFlush(display);
    
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
        
        // Launch Kate
        char *args[] = {
            "kate",
            "--desktopfile", "kate",
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
            
            // Check window PID
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
                    // Check if it's a real window
                    XWindowAttributes attrs;
                    if (XGetWindowAttributes(display, children[i], &attrs) &&
                        attrs.map_state != IsUnmapped &&
                        attrs.width > 100 && attrs.height > 100) {
                        
                        NSLog(@"Found Kate window %lu with PID %d", children[i], katePid);
                        [self embedWindow:children[i]];
                        break;
                    }
                }
            }
            
            // Also check by WM_CLASS as fallback
            if (!embedded) {
                XClassHint classHint;
                if (XGetClassHint(display, children[i], &classHint)) {
                    if (classHint.res_class && 
                        strcasecmp(classHint.res_class, "kate") == 0) {
                        
                        // Check if it's a top-level window
                        Window root_return, parent_return;
                        Window *children_return;
                        unsigned int nchildren_return;
                        
                        if (XQueryTree(display, children[i], &root_return, 
                                      &parent_return, &children_return, &nchildren_return)) {
                            if (children_return) XFree(children_return);
                            
                            if (parent_return == root || parent_return == DefaultRootWindow(display)) {
                                // Check window attributes
                                XWindowAttributes attrs;
                                if (XGetWindowAttributes(display, children[i], &attrs) &&
                                    attrs.width > 100 && attrs.height > 100) {
                                    NSLog(@"Found Kate window by class: %lu", children[i]);
                                    [self embedWindow:children[i]];
                                }
                            }
                        }
                    }
                    if (classHint.res_name) XFree(classHint.res_name);
                    if (classHint.res_class) XFree(classHint.res_class);
                    
                    if (embedded) break;
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
    
    // Select events on Kate window
    XSelectInput(display, kateWindow,
                StructureNotifyMask | PropertyChangeMask | FocusChangeMask);
    
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
    NSLog(@"Successfully embedded Kate window");
}

- (void)setFrame:(NSRect)frame
{
    [super setFrame:frame];
    if (!isMoving) {
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
    if (display && containerWindow) {
        XRaiseWindow(display, containerWindow);
        if (kateWindow) {
            XSetInputFocus(display, kateWindow, RevertToParent, CurrentTime);
        }
        XFlush(display);
    }
}

@end

@interface KateWrapperController : NSObject <NSApplicationDelegate>
{
    NSWindow *mainWindow;
    XEmbedView *embedView;
    NSTimer *positionUpdateTimer;
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
    
    // Force initial positioning
    [embedView updateContainerPosition];
    
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
    
    // Set up X11 event processing
    [self setupX11EventProcessing];
}

- (void)setupX11EventProcessing
{
    [NSTimer scheduledTimerWithTimeInterval:0.01
                                      target:self
                                    selector:@selector(processX11Events:)
                                    userInfo:nil
                                     repeats:YES];
}

- (void)processX11Events:(NSTimer*)timer
{
    Display *display = [embedView x11Display];
    if (!display) return;
    
    while (XPending(display)) {
        XEvent event;
        XNextEvent(display, &event);
        // Process events silently
    }
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    if (positionUpdateTimer) {
        [positionUpdateTimer invalidate];
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
