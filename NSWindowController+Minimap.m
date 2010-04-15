//
//  NSWindowController+Minimap.m
//  TextmateMinimap
//
//  Created by Julian Eberius on 09.02.10.
//  Copyright 2010 Julian Eberius. All rights reserved.
//

#import "NSWindowController+Minimap.h"
#import "MinimapView.h"
#import "TextMate.h"
#import "NSView+Minimap.h"
#import "TextMateMinimap.h"
#import "objc/runtime.h"
#import "MMCWTMSplitView.h"
#include "sys/xattr.h"

// stuff that the textmate-windowcontrollers (OakProjectController, OakDocumentControler) implement
@interface NSWindowController (TextMate_WindowControllers_Only)
- (id)textView;
- (void)goToLineNumber:(id)newLine;
- (unsigned int)getLineHeight;
// that is only implemented by OakProjectController
- (NSString*)filename;
@end

//stuff that textmate's textview implements
@interface NSView (TextMate_OakTextView_Only)
- (id)currentStyleSheet;
- (BOOL)storedSoftWrapSetting;
@end

@interface NSWindowController (Private_MM_NSWindowController)
- (NSRectEdge) getCorrectMinimapDrawerSide;
- (BOOL)shouldOpenMinimapDrawer:(NSString*)filename;
- (void)writeMinimapOpenStateToFileAttributes:(NSString*)filename;
- (NSRectEdge)getPreferableWindowSide;
- (BOOL)isInSidepaneMode;
- (BOOL)sidepaneIsClosed;
- (void)setSidepaneIsClosed:(BOOL)closed;
@end

const char* MINIMAP_STATE_ATTRIBUTE_UID = "textmate.minimap.state";

@implementation NSWindowController (MM_NSWindowController)

/*
 Request a redraw of the minimap
 */
- (void)refreshMinimap
{
  MinimapView* textShapeView = [self getMinimapView];
  [textShapeView refresh];
}

/*
 Get the currently selected line in the TextView, tip from TM plugin mailing list
 */
- (int)getCurrentLine:(id)textView
{
  NSMutableDictionary* dict = [NSMutableDictionary dictionary];
  [textView bind:@"lineNumber" toObject:dict
     withKeyPath:@"line"   options:nil];
  int line = [(NSNumber*)[dict objectForKey:@"line"] intValue];
  return line;
}

/*
 Open / close the minimap drawer
 */
- (void)toggleMinimap
{
  if ([self minimapContainerIsOpen])
    [self setMinimapContainerIsOpen:NO];
  else
    [self setMinimapContainerIsOpen:YES];
}

/*
 Call TextMate's gotoLine function
 */
- (void)scrollToLine:(unsigned int)newLine
{
  id textView = [self textView];
  MinimapView* textShapeView = [self getMinimapView];
  [textView goToLineNumber: [NSNumber numberWithInt:newLine]];
  [textShapeView refresh];
}

/*
 Find out whether soft wrap is enabled by looking at the applications main menu...
 */
- (BOOL) isSoftWrapEnabled
{
  return [[[self getMinimapView] textView] storedSoftWrapSetting];
}

/*
 Get this window's minimap
 */
- (MinimapView*) getMinimapView
{
  NSMutableDictionary* ivars = [[TextmateMinimap instance] getIVarsFor:self];
  return (MinimapView*)[ivars objectForKey:@"minimap"];
}

- (void)updateTrailingSpace
{
  if (![self isInSidepaneMode]) {
    NSDrawer* drawer = [self getMinimapDrawer];
    [drawer setTrailingOffset:[self isSoftWrapEnabled] ? 40 : 56];
  }
}

#pragma mark swizzled_methods
/*
 Swizzled method: on close
 - release  minimapDrawer
 - set lastWindowController to nil
 - save minimap state to file
 */
- (void)MM_windowWillClose:(id)aNotification
{
  //save minimapstate to extended file attribute
  NSString* filename = nil;
  if ([[self className] isEqualToString:@"OakProjectController"])
    filename = [self filename];
  else
    filename = [[[self textView] document] filename];
  if (filename != nil)
    [self writeMinimapOpenStateToFileAttributes:filename];

  NSDrawer* drawer = [self getMinimapDrawer];
  [drawer setContentView:nil];
  [drawer setParentWindow:nil];
  [[TextmateMinimap instance] setLastWindowController:nil];
  [[TextmateMinimap instance] releaseIVarsFor:self];
  // call original
  [self MM_windowWillClose:aNotification];
}

/*
 Swizzled Method: called when an project or document window was openened
 - set the "lastWindowController" (top most window as seen by the plugin)
 - create a drawer for the minimap and set it's side
 - OR create sidepane
 - set the correct offsets for the minimap (different for document and project controller)
 - store references and mode in "iVars"
 */
- (void)MM_windowDidLoad
{
  // call original
  [self MM_windowDidLoad];
  NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
  
  [[TextmateMinimap instance] setLastWindowController:self];
  NSWindow* window=[self window];
  NSSize contentSize = NSMakeSize(160, [window frame].size.height);
  NSRectEdge edge = [self getCorrectMinimapDrawerSide];
  // init textshapeview
  MinimapView* textshapeView = [[MinimapView alloc] initWithTextView:[self textView]];
  [textshapeView setWindowController:self];
  NSMutableDictionary* ivars = [[TextmateMinimap instance] getIVarsFor:self];
  NSString* filename = nil;
  
  
  if ([defaults boolForKey:@"Minimap_showInSidepane"]) {
    NSView* documentView = [[window contentView] retain];
    MMCWTMSplitView* splitView;
    // check whether projectplus or missingdrawer is present
    // if so, but our splitview into their splitview, not to confuse their implementation
    // (which sadly does [window contentView] to find it's own splitView)
    if (NSClassFromString(@"CWTMSplitView") != nil 
        && [[NSUserDefaults standardUserDefaults] boolForKey:@"ProjectPlus Sidebar Enabled"]) {
      
      NSView* preExistingSplitView = documentView;
      BOOL ppSidebarIsOnRight = [[NSUserDefaults standardUserDefaults] boolForKey:@"ProjectPlus Sidebar on Right"];
      
      NSView* realDocumentView;
      NSView* originalSidePane;
      if (ppSidebarIsOnRight) {
        realDocumentView = [[preExistingSplitView subviews] objectAtIndex:0];
        originalSidePane = [[preExistingSplitView subviews] objectAtIndex:1];
      }
      else {
        realDocumentView = [[preExistingSplitView subviews] objectAtIndex:1];
        originalSidePane = [[preExistingSplitView subviews] objectAtIndex:0];
      }
      
      [realDocumentView retain];[realDocumentView removeFromSuperview];
      [originalSidePane retain];[originalSidePane removeFromSuperview];
      
      splitView = [[MMCWTMSplitView alloc] initWithFrame:[realDocumentView frame]];
      [splitView setVertical:YES];
      [splitView setDelegate:[TextmateMinimap instance]];
      Boolean sidebarOnRight = (edge==NSMaxXEdge);
      [splitView setSideBarOnRight:sidebarOnRight];
      
      if(!sidebarOnRight)
        [splitView addSubview:textshapeView];
      [splitView addSubview:realDocumentView];
      if(sidebarOnRight)
        [splitView addSubview:textshapeView];
      
      if (ppSidebarIsOnRight)
        [preExistingSplitView addSubview:splitView];
      [preExistingSplitView addSubview:originalSidePane];
      if (!ppSidebarIsOnRight)
        [preExistingSplitView addSubview:splitView];    
      [realDocumentView release];
      [originalSidePane release];
    }
    // no relevant plugins present, init in contentView of Window
    else {
      [window setContentView:nil];
      
      splitView = [[MMCWTMSplitView alloc] initWithFrame:[documentView frame]];
      [splitView setVertical:YES];
      [splitView setDelegate:[TextmateMinimap instance]];
      Boolean sidebarOnRight = (edge==NSMaxXEdge);
      [splitView setSideBarOnRight:sidebarOnRight];
      
      if(!sidebarOnRight)
        [splitView addSubview:textshapeView];
      [splitView addSubview:documentView];
      if(sidebarOnRight)
        [splitView addSubview:textshapeView];
      
      [window setContentView:splitView];
    }
    
    [[splitView drawerView] setFrameSize:contentSize];
    
    if ([[self className] isEqualToString:@"OakProjectController"]) {
      filename = [self filename];
    }
    else if ([[self className] isEqualToString:@"OakDocumentController"]) {
      filename = [[[self textView] document] filename];
    }
    BOOL shouldOpen = [self shouldOpenMinimapDrawer:filename];
    [self setMinimapContainerIsOpen:shouldOpen];
      
    [[NSUserDefaults standardUserDefaults] setBool:shouldOpen forKey:@"Minimap_lastDocumentHadMinimapOpen"];
    [ivars setObject:[NSNumber numberWithBool:YES]  forKey:@"minimapSidepaneModeOn"];
    [ivars setObject:splitView  forKey:@"minimapSplitView"];
    [splitView release];
    [documentView release];
  }
  else {
    id minimapDrawer = [[NSDrawer alloc] initWithContentSize:contentSize preferredEdge:edge];
    [minimapDrawer setParentWindow:window];
    [minimapDrawer setContentView:textshapeView];
    
    int trailingOffset = [self isSoftWrapEnabled] ? 40 : 56;
    if ([[self className] isEqualToString:@"OakProjectController"]) {
      [minimapDrawer setTrailingOffset:trailingOffset];
      [minimapDrawer setLeadingOffset:24];
      filename = [self filename];
    }
    else if ([[self className] isEqualToString:@"OakDocumentController"]) {
      [minimapDrawer setTrailingOffset:trailingOffset];
      [minimapDrawer setLeadingOffset:0];
      filename = [[[self textView] document] filename];
    }
    [ivars setObject:minimapDrawer forKey:@"minimapDrawer"];
    BOOL shouldOpen = [self shouldOpenMinimapDrawer:filename];
    if (shouldOpen)
      [minimapDrawer openOnEdge:edge];
    [[NSUserDefaults standardUserDefaults] setBool:shouldOpen forKey:@"Minimap_lastDocumentHadMinimapOpen"];
    [minimapDrawer release];
    [ivars setObject:[NSNumber numberWithBool:NO]  forKey:@"minimapSidepaneModeOn"];
  }
  
  [ivars setObject:textshapeView forKey:@"minimap"];
  [textshapeView release];
}

- (BOOL)minimapContainerIsOpen {
  if ([self isInSidepaneMode]) {
    return ![self sidepaneIsClosed];
  } 
  else {
    NSDrawer* drawer = [self getMinimapDrawer];
    int state = [drawer state];
    return ((state == NSDrawerOpeningState) || (state == NSDrawerOpenState));
  }
}

- (void)setMinimapContainerIsOpen:(BOOL)open {
  if (!open) {
    if ([self isInSidepaneMode]) {
      [self setSidepaneIsClosed:!open];
    } 
    else {
        [[self getMinimapDrawer] close];
    }  
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"Minimap_lastDocumentHadMinimapOpen"];
  }
  else {
    if ([self isInSidepaneMode]) {
      [self setSidepaneIsClosed:!open];
    } 
    else {
        NSRectEdge edge = [self getCorrectMinimapDrawerSide];
        [[self getMinimapDrawer] openOnEdge:edge];
    }
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"Minimap_lastDocumentHadMinimapOpen"];
  }
}

- (BOOL)isInSidepaneMode {
  NSMutableDictionary* ivars = [[TextmateMinimap instance] getIVarsFor:self];
  return [[ivars objectForKey:@"minimapSidepaneModeOn"] boolValue];
}

/*
  do not call directly! use minimapContainerIsOpen
  */
- (BOOL)sidepaneIsClosed
{
  NSMutableDictionary* ivars = [[TextmateMinimap instance] getIVarsFor:self];
  MMCWTMSplitView* splitView = (MMCWTMSplitView*)[ivars objectForKey:@"minimapSplitView"];
  return [splitView isSubviewCollapsed:[splitView drawerView]];
}

/*
  do not call directly! use setMinimapContainerIsOpen
  */
- (void)setSidepaneIsClosed:(BOOL)closed
{
  NSMutableDictionary* ivars = [[TextmateMinimap instance] getIVarsFor:self];
  MMCWTMSplitView* splitView = (MMCWTMSplitView*)[ivars objectForKey:@"minimapSplitView"];
  [splitView setSubview:[splitView drawerView] isCollapsed:closed];
  [splitView resizeSubviewsWithOldSize:[splitView bounds].size];
}

/*
 Swizzled method: called when the project drawer is opened or closed
 */
- (void)MM_toggleGroupsAndFilesDrawer:(id)sender
{
  [self MM_toggleGroupsAndFilesDrawer:sender];
  // if auto-mode is set, we need to check whether both drawers are now on the same side, in which case we need to
  // close the minimap and reopen it on the other side
  if ([[NSUserDefaults standardUserDefaults] integerForKey:@"Minimap_minimapSide"] == MinimapAutoSide) {
    // the following code is quite ugly... well it works for now :-)
    NSDrawer* projectDrawer = nil;
    for (NSDrawer *drawer in [[self window] drawers])
      if (! [[drawer contentView] isKindOfClass:[MinimapView class]])
        projectDrawer = drawer;
        
    // if no drawer is found, we're running ProjectPlus or MissingDrawer...
    // if we're in sidepane mode, this is all irrelephant(http://irrelephant.net/)
    if (projectDrawer == nil || [self isInSidepaneMode]) {
      return;
    }
    // the regular old case: both are drawers!
    NSDrawer* minimapDrawer = [self getMinimapDrawer];
    int projectDrawerState = [projectDrawer state];
    if ((projectDrawerState == NSDrawerOpeningState) || (projectDrawerState == NSDrawerOpenState))
    {
      
      if ([projectDrawer edge] == [minimapDrawer edge])
      {
        [minimapDrawer close];
        [[NSNotificationCenter defaultCenter] addObserver:self
                             selector:@selector(reopenMinimapDrawer:)
                               name:NSDrawerDidCloseNotification object:minimapDrawer];
      }
    }
  }
}

-(void)MM_PrefWindowWillClose:(id)arg1
{
  [self MM_PrefWindowWillClose:arg1];
  [[[TextmateMinimap instance] lastWindowController] refreshMinimap];
}


#pragma mark private

- (NSDrawer*) getMinimapDrawer
{
  NSMutableDictionary* ivars = [[TextmateMinimap instance] getIVarsFor:self];
  return (NSDrawer*)[ivars objectForKey:@"minimapDrawer"];
}

- (BOOL) shouldOpenMinimapDrawer:(NSString*)filename
{
  BOOL result = YES;
  NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
  int openBehaviour = [defaults integerForKey:@"Minimap_openDocumentBehaviour"];
  int newDocBehaviour = [defaults integerForKey:@"Minimap_newDocumentBehaviour"];

  // check the extended file attributes
  char value;
  int success = getxattr([filename UTF8String], MINIMAP_STATE_ATTRIBUTE_UID, &value, 1, 0, 0);

  // if there it is a new file || the openBehaviour is the same as for new files || the extended-file-attribute isn't set
  if ((filename == nil) || (openBehaviour == MinimapAsNewDocument) || success == -1) {
    switch (newDocBehaviour) {
      default:
      case MinimapInheritShow:
        result = [defaults boolForKey:@"Minimap_lastDocumentHadMinimapOpen"];
        break;
      case MinimapAlwaysShow:
        result = YES;
        break;
      case MinimapNeverShow:
        result = NO;
        break;
    }
  }
  else if (success == 1) {
    if (value==0x31) {
      result = YES;
    } else if (value==0x30) {
      result = NO;
    }
  }
  return result;
}

/*
 Private method: Saves the open state of the minimap into the extended file attributes
 */
- (void)writeMinimapOpenStateToFileAttributes:(NSString*)filename
{
  char value;
  NSDrawer* drawer = [self getMinimapDrawer];
  if (([drawer state] == NSDrawerOpenState) || ([drawer state] == NSDrawerOpeningState))
    value = 0x31; // xattr (on terminal) reads the extended file attributes as utf8 strings, this is the utf8 "1"
  else
    value = 0x30; // this is the "0"
  setxattr([filename UTF8String], MINIMAP_STATE_ATTRIBUTE_UID, &value, 1, 0, 0);
}

/*
 Private method: called by NSNotificationCenter when the minimapDrawer sends "DidClose"
 reopen minimapDrawer on the opposite side
 */
- (void)reopenMinimapDrawer:(NSNotification *)notification
{
  NSDrawer* drawer = [self getMinimapDrawer];
  if ([drawer edge] == NSMaxXEdge)
    [drawer openOnEdge:NSMinXEdge];
  else
    [drawer openOnEdge:NSMaxXEdge];

  [[NSNotificationCenter defaultCenter] removeObserver:self name:NSDrawerDidCloseNotification object:drawer];
}

/*
 Find out on which side the minimap drawer should appear
 */
- (NSRectEdge) getCorrectMinimapDrawerSide
{
  int result;
  NSRectEdge projectDrawerSide = NSMaxXEdge;
  Boolean projectDrawerIsOpen = NO;
  Boolean projectDrawerWasFound = NO;
  for (NSDrawer *drawer in [[self window] drawers])
    if (! [[drawer contentView] isKindOfClass:[MinimapView class]]) {
      projectDrawerWasFound = YES;
      projectDrawerSide = [drawer edge];
      projectDrawerIsOpen = ([drawer state] == NSDrawerOpeningState) 
                        || ([drawer state] == NSDrawerOpenState);
    }
  switch ([[NSUserDefaults standardUserDefaults] integerForKey:@"Minimap_minimapSide"]) {
    default:
    case MinimapAutoSide:
      if (projectDrawerWasFound) {
        if (projectDrawerSide == NSMaxXEdge)
          if (projectDrawerIsOpen) result = NSMinXEdge;
          else result = NSMaxXEdge;
        else
          if (projectDrawerIsOpen) result = NSMaxXEdge;
          else result = NSMinXEdge;
      }
      // there is no project drawer we can use for orientation, let's find a side ourselves!
      else {
        result = [self getPreferableWindowSide];
      }
      break;

    case MinimapLeftSide:
      result = NSMinXEdge;
      break;

    case MinimapRightSide:
      result = NSMaxXEdge;
      break;
  }

  return result;
}

/*
  private method: finds the side of the window with more space to the screen's edge
*/
- (NSRectEdge)getPreferableWindowSide 
{
  NSRectEdge result = NSMaxXEdge;
  
  NSWindow* window = [self window];
  NSRect windowFrame = [window frame];
  if ((windowFrame.origin.x) > ([[window screen] frame].size.width - (windowFrame.origin.x+windowFrame.size.width)))
    result = NSMinXEdge;
    
  return result;
}

@end