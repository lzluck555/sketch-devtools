//
//  SketchConsole.m
//  SketchConsole
//
//  Created by Andrey on 21/08/14.
//  Copyright (c) 2014 Andrey Shakhmin. All rights reserved.
//

#import "SketchConsole.h"
#import <objc/runtime.h>

#import <WebKit/WebKit.h>
#import "SDTSwizzle.h"

#import "SDTModule.h"
#import "NSString+SketchDevTools.h"
#import "NSView+SketchDevTools.h"

#import "NSLogger.h"
#import "SDTFileWatcher.h"


#import "CDTypeFormatter.h"
#import "CDBalanceFormatter.h"
#import "CDOCInstanceVariable.h"
#import "CDOCInstanceVariable.h"


#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"


#define INIT_FILE_WATCHERS false



@implementation SketchConsole

+(void)load {
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        
        // COScript.printException:
        // Exceptions handling.
        [SDTSwizzle swizzleMethod:@selector(printException:) withMethod:@selector(printException:) sClass:[self class] pClass:NSClassFromString(@"COScript") originalMethodPrefix:@"originalCOScript_"];
        
        // MSPlugin.run;
        // Plugin session handling
        [SDTSwizzle swizzleMethod:@selector(run) withMethod:@selector(run) sClass:[self class] pClass:NSClassFromString(@"MSPlugin") originalMethodPrefix:@"originalMSPlugin_"];
        
        // COScript.executeString:baseURL:
        // print/log functions replacement.
        [SDTSwizzle swizzleMethod:@selector(executeString:baseURL:) withMethod:@selector(executeString:baseURL:) sClass:[self class] pClass:NSClassFromString(@"COScript") originalMethodPrefix:@"originalCOScript_"];
        
        // COSPreprocessor.preprocessForObjCStrings:
        // Fixing bug with block comments being ripped off.
        [SDTSwizzle swizzleClassMethod:@selector(preprocessForObjCStrings:) withMethod:@selector(preprocessForObjCStrings:) sClass:self pClass:NSClassFromString(@"COSPreprocessor") originalMethodPrefix:@"originalCOSPreprocessor_"];

    });
}


- (id)executeString:(NSString*)str baseURL:(NSURL*)base {
    
    // We need a reference to the actual Mocha runtime.
    Ivar nameIVar = class_getInstanceVariable([self class], "_mochaRuntime");
    id mocha = object_getIvar(self, nameIVar);
    
    // Remove methods added by COScript.
    [mocha setNilValueForKey:@"print"];
    [mocha setNilValueForKey:@"log"];
    
    // Load special script that simulates standard print/log statements behaviour.
    NSString *file = [[NSBundle bundleForClass:[SketchConsole class]] pathForResource:@"printVandalizer" ofType:@"js"];
    NSString *printScript = [NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:NULL];
    
    // Evauluate script.
    id newScript=[mocha performSelector:NSSelectorFromString(@"evalString:") withObject:printScript];
    
    // Add global print/log methods to current COScript session.
    [self performSelector:NSSelectorFromString(@"pushObject:withName:") withObject:newScript withObject:@"print"];
    [self performSelector:NSSelectorFromString(@"pushObject:withName:") withObject:newScript withObject:@"log"];

    
    // Invoke original method.
    if ([self respondsToSelector:NSSelectorFromString(@"originalCOScript_executeString:baseURL:")]) {
        return [self performSelector:NSSelectorFromString(@"originalCOScript_executeString:baseURL:") withObject:str withObject:base];
    } else {
        // [SketchConsole printGlobal:@"originalCOScript_executeString:baseURL: Does not respond to selector!"];
    }
    
    return nil;
}

// FIXME: This is a dirty hack to fix the problem with not refreshing console when print() function called from timer or target action function.
//        Should be replaced with a holistic solution. ))
+(void)refreshConsole {
    [SketchConsole callJSFunction:@"refreshConsoleList" withArguments:@[]];
}

// MSPlugin.run()
// This swizzled method is used to cache imports tree, collect information about current session and refresh client view.
- (id)run {
    
    // Session start timestamp.
    NSDate *start = [NSDate date];

    NSString* script=[self valueForKey:@"script"];
    NSURL* baseURL=[self valueForKey:@"url"];
    // NSURL* root=[self valueForKey:@"root"];
    
    // Caching imports tree for future use in print and exceptions handlers.
    SketchConsole* shared=[SketchConsole sharedInstance];
    
    shared.sessionScriptURL=baseURL;
    
    // FIXME: Need it for the dirty hack with refreshing.
    shared.finished = false;
    
    shared.isNewSession=true;
    if(shared.isNewSession) {
        shared.brokenImports=nil;
        shared.validImports=nil;
        
        SDTModule* module=[[SDTModule alloc] initWithScriptSource:script baseURL:baseURL parent:nil startLine:0];
        shared.cachedScriptRoot=module;
        
        shared.isNewSession=false;
    }
    
    // Clear console before script launch.
    if([(NSNumber*)shared.options[@"clearConsoleBeforeLaunch"] boolValue]) {
        [SketchConsole clearConsole];
    }
    
    // Check for broken imports.
    if(shared.brokenImports!=nil) {
        for(NSDictionary* importException in shared.brokenImports) {
            [SketchConsole callJSFunction:@"addBrokenImportItem" withArguments:@[importException[@"path"],[importException[@"url"] path],importException[@"line"]]];
        }
        
        [SketchConsole callJSFunction:@"refreshConsoleList" withArguments:@[]];
        
        return nil;
    }
    
    // Check for duplicate imports.
    if(shared.validImports!=nil) {
        for(NSString* key in shared.validImports.allKeys) {
            NSMutableDictionary* import=shared.validImports[key];
            if([import[@"count"] integerValue]>1) {
                NSDictionary* duplicateImportInfo =
                @{
                  @"filePath": key,
                  @"imports": import[@"imports"]
                  };
                
                
                NSString* json=[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:duplicateImportInfo options:NSJSONWritingPrettyPrinted error:nil] encoding:NSUTF8StringEncoding];
                
                [SketchConsole callJSFunction:@"addDuplicateImportItem" withArguments:@[json]];
            }
        }
        
        [SketchConsole callJSFunction:@"refreshConsoleList" withArguments:@[]];
        
    }
    
    // Invoke original MSPlugin.run method.
    id result=[self performSelector:NSSelectorFromString(@"originalMSPlugin_run")];
    
    // Add session item to the client view.
    if([(NSNumber*)shared.options[@"showSessionInfo"] boolValue]) {
        NSTimeInterval interval = [[NSDate date] timeIntervalSinceDate:start];
        [SketchConsole callJSFunction:@"addSessionItem" withArguments:@[[baseURL path],@(interval)]];
    }
    
    // Referesh console client view.
    [SketchConsole callJSFunction:@"refreshConsoleList" withArguments:@[]];
    
    // FIXME: Need it for the dirty hack with refreshing.
    shared.finished = true;
    
    return result;
}

+(NSDictionary*)getExternalFiles:(NSURL*)scriptURL {

    NSURL* pluginFolderURL=[scriptURL URLByDeletingLastPathComponent];
    return @{
             @"folder": pluginFolderURL,
             @"index": [pluginFolderURL URLByAppendingPathComponent:@"index.html"]
             };
}

+(NSView*)getCurrentContentView {
    id document=[(NSClassFromString(@"MSDocument")) performSelector:NSSelectorFromString(@"currentDocument")];
    
    NSWindow* window=[document valueForKey:@"documentWindow"];
    return window.contentView;
}


+(SketchConsole*)sharedInstance {
    static dispatch_once_t once;
    static SketchConsole *sharedInstance;
    dispatch_once(&once, ^ { sharedInstance = [[self alloc] init]; });
    return sharedInstance;
}

@synthesize options = _options;


- (void) setOptions:(NSDictionary *)options {
    NSURL* fileURL=[[self.scriptURL URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"consoleOptions.json"];
    
    NSString* jsonOptions=[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:options options:NSJSONWritingPrettyPrinted error:nil] encoding:NSUTF8StringEncoding];
    [jsonOptions writeToURL:fileURL atomically:false encoding:NSUTF8StringEncoding error:nil];
    
    _options = options;
}

- (NSDictionary*) options {
    
    NSURL* fileURL=[[self.scriptURL URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"consoleOptions.json"];
    
    if(_options==nil) {
        if([[NSFileManager defaultManager] fileExistsAtPath:[fileURL path]]) {
            NSString* jsonOptions=[NSString stringWithContentsOfURL:fileURL encoding:NSUTF8StringEncoding error:nil];
            _options=[NSJSONSerialization JSONObjectWithData:[jsonOptions dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        }
    }
    
    return _options;
}

+(void)callJSFunction:(NSString*)name withArguments:(NSArray*)args {
    WebView* webView =[self findWebView];
    if(webView!=nil) {
        [[webView windowScriptObject] callWebScriptMethod:name withArguments:args];
    }
}

+(void)customPrint:(id)s {
    if(s==nil) {
        s=@"(null)";
    }
    
    // If logged value is an object we should convert it to a string.
    if (![s isKindOfClass:[NSString class]]) {
        s = [[s description] sdt_escapeHTML];
    }
    
    // Add custom print item to the client.
    [self callJSFunction:@"addCustomPrintItem" withArguments:@[s]];
}

+(void)wtf:(id)s {
    if(s==nil) {
        s=@"(null)";
    }
    
    if (![s isKindOfClass:[NSString class]]) {
        s = [[s description] sdt_escapeHTML];
    }
    
    [self callJSFunction:@"addWtfItem" withArguments:@[s]];
}


+(void)extendedPrint:(id)s info:(NSDictionary*)info sourceScript:(NSString*)script {

    // Should convert null value to a string representation.
    if(s==nil) {
        s=@"(null)";
    }
    
    // If logged value is an object we should convert it to a string and escape all the HTML symbols.
    if (![s isKindOfClass:[NSString class]]) {
        s = [[s description] sdt_escapeHTML];
    }
    
    SketchConsole* shared=[self sharedInstance];
    if(shared.cachedScriptRoot!=nil) {
        
        // Get actual file and line number frome where print statement was called.
        SDTModule* module=[shared.cachedScriptRoot findModuleByLineNumber:[(NSNumber*)info[@"line"] integerValue]];
        NSInteger line=[module relativeLineByAbsolute:[(NSNumber*)info[@"line"] integerValue]];
        
        // Add print item to the client.
        [self callJSFunction:@"addPrintItemEx" withArguments:@[s,[module.url path],@(line)]];
    }
};

// COScript.printException() - this method is responsible for the JS and Mocha exceptions handling.
- (void)printException:(NSException*)e {
    
    [SketchConsole ensureConsoleVisible];
    
    // Invoke original COScript.printException() method.
    if(true) {
        if ([self respondsToSelector:NSSelectorFromString(@"originalCOScript_printException")]) {
            [self performSelector:NSSelectorFromString(@"originalCOScript_printException") withObject:e];
        } else {
            // NSLog(@"COScript.printException: Does not respond to selector!");
        }
    }
    
    // Check for JS errors.
    if([e.name isEqualToString:@"MOJavaScriptException"]) {
    
        NSString* errorType=@"JSUnknownError";
        NSString* message=@"";
        NSDictionary* errors=
        @{
          @"ReferenceError: " : @"JSReferenceError",
          @"TypeError: " : @"JSTypeError",
          @"SyntaxError: " : @"JSSyntaxError",
          @"RangeError: " : @"JSRangeError",
          @"EvalError: " : @"JSEvalError",
          @"InternalError: " : @"JSInternalError",
          @"URIError: " : @"JSURIError",
          @"Error: " : @"JSCustomError"
          };

        // Get error type and the message.
        for (NSString* key in errors) {
            if([e.reason rangeOfString:key].location==0) {
                errorType=errors[key];
                message=[e.reason stringByReplacingOccurrencesOfString:key withString:@""];
                break;
            }
        }
        
        SketchConsole* shared=[SketchConsole sharedInstance];
        if(shared.cachedScriptRoot) {
            
            // Process call stack.
            NSArray* stack=[e.userInfo[@"stack"] componentsSeparatedByString:@"\n"];
            NSMutableArray* callStack = [NSMutableArray arrayWithArray:@[]];
            
            for(NSString* call in stack) {
                NSArray* components=[call componentsSeparatedByString:@"@"];
                
                NSString* fn=(components.count>1) ? components[0] : @"closure";
                components=[components[components.count-1] componentsSeparatedByString:@":"];
                
                // NSString* filePath=components[0];
                NSUInteger line=[components[1] integerValue];
                NSUInteger column=[components[2] integerValue];
                SDTModule* module=[shared.cachedScriptRoot findModuleByLineNumber:line];
                if(module) {
                    NSUInteger relativeLineNumer=[module relativeLineByAbsolute:line];
                    NSString* sourceCodeLine=[module sourceCodeForLine:relativeLineNumer];
                    
                    NSDictionary* call=@{
                                        @"fn": fn,
                                        @"filePath" : [module.url path],
                                        @"line": @(relativeLineNumer),
                                        @"column": @(column),
                                        @"lineSrc": sourceCodeLine
                                        };
                    
                    [callStack addObject:call];
                }
            }
            
            // Looking for the file and line where error had happened and adding appropriate item to the client view.
            NSString* callStackObj=[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:callStack options:0 error:nil] encoding:NSUTF8StringEncoding];
            NSUInteger lineNumber=[(NSNumber*)e.userInfo[@"line"] integerValue];
            SDTModule* module=[shared.cachedScriptRoot findModuleByLineNumber:lineNumber];
            if(module) {
                NSUInteger relativeLineNumer=[module relativeLineByAbsolute:lineNumber];
                NSString* sourceCodeLine=[module sourceCodeForLine:relativeLineNumer];
                [SketchConsole callJSFunction:@"addErrorItem" withArguments:@[errorType,message,[module.url path],@(relativeLineNumer),sourceCodeLine,callStackObj]];
                
                
                // Auto-highlight line number in case we are running in custom script editor.
                // FIXME: There should be more sophisticated way to know whether we are running in custom script editor!
                if([[module.url lastPathComponent] isEqualToString:@"Untitled.sketchplugin"]) {
                    [shared showCustomScriptWindow:relativeLineNumer];
                }
                
            } else {
                // NSLog(@"Error: Can't find source module!");
            }
            
        } else {
            // NSLog(@"Error: Root module is not found!");
        }
        
        return;
    }
    
    // Check for Mocha runtime error.
    if([e.name isEqualToString:@"MORuntimeException"]) {
        SketchConsole* shared=[SketchConsole sharedInstance];
        if(shared) {
            [SketchConsole callJSFunction:@"addMochaErrorItem" withArguments:@[e.reason,[shared.sessionScriptURL path]]];
        }
    }
}


+(BOOL)initConsole:(NSURL*)scriptURL {
    
    [SketchConsole sharedInstance].scriptURL=scriptURL;

    // Internal file watchers for dynamic WebView reloading.
    if(INIT_FILE_WATCHERS) {
        [self initFileWatchers];
    }

    // Initialize Panel
    NSView* contentView=[self getCurrentContentView];
    if(contentView==nil) return false;
    
    int viewHeight=contentView.frame.size.height;
    int defaultConsoleHeight=[self defaultConsoleHeight];
    if(viewHeight/2<defaultConsoleHeight) defaultConsoleHeight=viewHeight/2;
    
    // Create WebView
    WebView* webView = [[WebView alloc] init];
    [webView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    webView.identifier=@"idConsoleWebView";
    
    // Create SplitView for substitution
    NSSplitView* splitView = [[NSSplitView alloc] initWithFrame:[contentView bounds]];
    splitView.autoresizingMask=NSViewWidthSizable | NSViewHeightSizable;
    splitView.identifier=@"idSketchDevToolsSplitter";
    
    
    NSSplitView* originalSplitView=contentView.subviews[0];
    
    [splitView addSubview:originalSplitView];
    [splitView addSubview:webView];
    
    [splitView adjustSubviews];
    
    // Replace default split view with the custom one.
    contentView.subviews=@[splitView];
    
    // Set position.
    [splitView setPosition:viewHeight-defaultConsoleHeight ofDividerAtIndex:0];
    

    // Scripts exposer.
    [webView setFrameLoadDelegate:[self sharedInstance]];
    
    // Load web-page and initialize console.
    NSDictionary* files=[self getExternalFiles:scriptURL];
    NSString* indexPageContents=[NSString stringWithContentsOfFile:[files[@"index"] path] encoding:NSUTF8StringEncoding error:nil];
    [[webView mainFrame] loadHTMLString:indexPageContents baseURL:files[@"folder"]];
    
    return true;
}

+(BOOL)isConsoleInitialized {
    return ([self findWebView]==nil ? false : true);
}


+(id)persistentStorageGetValueForKey:(NSString*)key {
    NSDictionary* persistent = [[NSThread mainThread] threadDictionary];
    return persistent[key];
}

+(void)persistentStorageSetValue:(id)value forKey:(NSString*)key {
    NSDictionary* persistent = [[NSThread mainThread] threadDictionary];
    [persistent setValue:value forKey:key];
}

+(int)defaultConsoleHeight {
    
    int defaultValue=300;
    
    NSString* docObjectID=[self crrentDocumentObjectID];
    if(docObjectID==nil) return defaultValue;
    
    NSNumber* value=[self persistentStorageGetValueForKey:[NSString stringWithFormat:@"SketchDevTools-ConsoleHeight-%@",docObjectID]];
    if(value==nil) {
        return defaultValue;
    }
    
    return value.intValue;
}

+(void)saveDefaultConsoleHeight:(int)height {
    
    NSString* docObjectID=[self crrentDocumentObjectID];
    if(docObjectID==nil) return;
    
    [self persistentStorageSetValue:[NSNumber numberWithInt:height] forKey:[NSString stringWithFormat:@"SketchDevTools-ConsoleHeight-%@",docObjectID]];
    
}

+(void)ensureConsoleVisible {
    
    NSNumber* showConsoleOnError=[SketchConsole sharedInstance].options[@"showConsoleOnError"];
    if(![showConsoleOnError boolValue]) {
        return;
    }
    
    NSView* contentView=[SketchConsole getCurrentContentView];
    if(contentView==nil) return;
    
    int defaultConsoleHeight=[self defaultConsoleHeight];
    int viewHeight=contentView.frame.size.height;
    
    NSSplitView* splitView=(NSSplitView*)[[SketchConsole getCurrentContentView] subviewWithID:@"idSketchDevToolsSplitter"];
    if(splitView==nil) return;
    
    WebView* webView=[SketchConsole findWebView];
    if(webView==nil) return;
    
    if(webView.frame.size.height==0) {
        [splitView setPosition:viewHeight-defaultConsoleHeight ofDividerAtIndex:0];
    }
}

+(void)showHideConsole:(NSURL*)scriptURL {
    
    if(![self isConsoleInitialized]) {
        [self initConsole:scriptURL];
        return;
    }
    
    NSView* contentView=[self getCurrentContentView];
    if(contentView==nil) return;
    
    int defaultConsoleHeight=[self defaultConsoleHeight];
    int viewHeight=contentView.frame.size.height;
    
    NSSplitView* splitView=(NSSplitView*)[[self getCurrentContentView] subviewWithID:@"idSketchDevToolsSplitter"];
    if(splitView==nil) return;
    
    WebView* webView=[self findWebView];
    if(webView==nil) return;
    
    if(webView.frame.size.height==0) {
        
        [splitView setPosition:viewHeight-defaultConsoleHeight ofDividerAtIndex:0];
        
    } else {
        [self saveDefaultConsoleHeight:webView.frame.size.height];
        [splitView setPosition:viewHeight ofDividerAtIndex:0];
    }
}

-(void)hideConsole {
    NSView* contentView=[SketchConsole getCurrentContentView];
    if(contentView==nil) return;

    int viewHeight=contentView.frame.size.height;
    
    NSSplitView* splitView=(NSSplitView*)[[SketchConsole getCurrentContentView] subviewWithID:@"idSketchDevToolsSplitter"];
    if(splitView==nil) return;
    
    WebView* webView=[SketchConsole findWebView];
    if(webView==nil) return;
    
    [SketchConsole saveDefaultConsoleHeight:webView.frame.size.height];
    [splitView setPosition:viewHeight ofDividerAtIndex:0];
}


+(WebView*)findWebView {
    NSView* contentView=[self getCurrentContentView];
    if(contentView==nil) return nil;
    
    NSView* splitter=[contentView subviewWithID:@"idSketchDevToolsSplitter"];
    if(splitter) {
        return (WebView*)[splitter subviewWithID:@"idConsoleWebView"];
        
    } else {
        return nil;
    }
    
    return nil;
}

+(NSString*)crrentDocumentObjectID {
    NSDocumentController* controller=[NSDocumentController sharedDocumentController];
    NSDocument* doc=controller.currentDocument;
    
    if([doc respondsToSelector:NSSelectorFromString(@"documentData")]) {
        id docData=[doc performSelector:NSSelectorFromString(@"documentData")];
        if(docData) {
            if([docData respondsToSelector:NSSelectorFromString(@"objectID")]) {
                NSString* objectID=[docData performSelector:NSSelectorFromString(@"objectID")];
                return objectID;
            }
        }
    }
    
    return nil;
}

+(void)clearConsole {
    [self callJSFunction:@"clearConsole" withArguments:@[]];
}

-(void)openURL:(NSString*)url {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:url]];
}

-(NSString*)getConsoleOptions {
    return [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:[SketchConsole sharedInstance].options options:NSJSONWritingPrettyPrinted error:nil] encoding:NSUTF8StringEncoding];
}

-(void)setConsoleOptions:(NSString*)options {
    [SketchConsole sharedInstance].options=[NSJSONSerialization JSONObjectWithData:[options dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
}


// Methods exposed to WebKit as part of SketchDevTools object.
+(NSString*)webScriptNameForSelector:(SEL)sel
{
    NSString* name=@"";
    
    if (sel == @selector(filePathToFileURL:))
        name = @"filePathToFileURL";
    
    if (sel == @selector(hideConsole))
        name = @"hideConsole";
    
    if (sel == @selector(openURL:))
        name = @"openURL";
    
    if (sel == @selector(getConsoleOptions))
        name = @"getConsoleOptions";
    
    if (sel == @selector(setConsoleOptions:))
        name = @"setConsoleOptions";
    
    if (sel == @selector(showCustomScriptWindow:))
        name = @"showCustomScriptWindow";
    
    if (sel == @selector(runScript:))
        name = @"runScript";
    
    
    
    return name;
}

+ (BOOL)isSelectorExcludedFromWebScript:(SEL)sel
{
    if (sel == @selector(filePathToFileURL:)) return NO;
    if (sel == @selector(hideConsole)) return NO;
    if (sel == @selector(openURL:)) return NO;
    if (sel == @selector(getConsoleOptions)) return NO;
    if (sel == @selector(setConsoleOptions:)) return NO;
    if (sel == @selector(showCustomScriptWindow:)) return NO;
    if (sel == @selector(runScript:)) return NO;

    return YES;
}

-(NSString*)filePathToFileURL:(NSString*)filePath {
    return [[NSURL fileURLWithPath:filePath] description];
}

-(void)showCustomScriptWindow:(NSInteger)lineNumber {
    
    // Looking for already opened sheet.
    NSWindowController* sheet=nil;
    
    NSWindow* mainWindow=[[NSApplication sharedApplication] mainWindow];
    if(mainWindow==nil) return;
    
    if(mainWindow.attachedSheet!=nil) {
        NSWindowController* controller=(NSWindowController*)mainWindow.attachedSheet.delegate;
        if(controller!=nil && [controller isKindOfClass:NSClassFromString(@"MSRunCustomScriptSheet")]) {
            sheet=controller;
        }
    }

    // If it doesn't exist we have to show it first.
    if(sheet==nil) {
        sheet=objc_msgSend(NSClassFromString(@"MSRunCustomScriptSheet"),NSSelectorFromString(@"runForWindow:"),[[NSApplication sharedApplication] mainWindow]);
    }
    
    NSTextView* (^findScriptTextView)(void) = ^NSTextView*(void) {
        
        NSView* logView=objc_msgSend(sheet,NSSelectorFromString(@"logField"));
        
        NSArray* views=[(NSView*)sheet.window.contentView subviews];
        for (NSView* view in views) {
            if([view.className isEqualToString:@"NSSplitView"]) {
                
                for (NSScrollView* splitSubView in view.subviews) {
                    NSView* documentView=splitSubView.documentView;
                    if([documentView.className isEqualToString:@"NSTextView"] && ![documentView.identifier isEqualToString:logView.identifier]) {
                        return (NSTextView*)documentView;
                    }
                }
            }
        }
        
        return nil;
    };

    NSTextView* textView=findScriptTextView();
    if(textView!=nil) {
        NSString* text=textView.textStorage.string;
        NSArray* lines=[text componentsSeparatedByString:@"\n"];
        
        NSInteger count=0;
        for(int i=0;i<lineNumber-1;i++) {
            count+=[(NSString*)lines[i] length]+1;
        }
        
        NSRange selectedrange=NSMakeRange(count, [lines[lineNumber-1] length]);
        [textView setSelectedRange:selectedrange];
        [textView scrollRangeToVisible:selectedrange];
        
        // FIXME: Not sure it's the best solution.. may be it might be better to keep system selection color?
        NSDictionary* attributes = [NSDictionary dictionaryWithObjectsAndKeys:
                                    [NSColor colorWithRed:219.0/255.0 green:82.0/255.0 blue:75.0/255.0 alpha:1], NSBackgroundColorAttributeName, /* something obvious so I can see it */
                                    [NSColor whiteColor], NSForegroundColorAttributeName,
                                    nil];
        [textView setSelectedTextAttributes:attributes];
    }
};

+(id)testObject:(id)object {
    return [object description];
}

+(id)getPropertyData:(Class)objectClass accessorKey:(NSString*)accessorKey {
    
    objc_property_t prop = class_getProperty(objectClass, [accessorKey UTF8String]);
    
    NSString* getter=@"";
    NSString* setter=@"";
    
    char *setterName = property_copyAttributeValue(prop, "S");
    if (setterName == NULL) {
        setter=accessorKey;
    } else {
        setter = [NSString stringWithUTF8String:setterName];
    }
    
    char *getterName = property_copyAttributeValue(prop, "G");
    if (getterName == NULL) {
        getter = accessorKey;
    } else {
        getter = [NSString stringWithUTF8String:getterName];
    }
    
    return @{
             @"setter" : setter,
             @"getter" : getter
             };
};

+ (NSString*)preprocessForObjCStrings:(NSString*)sourceString {
    NSMutableString *buffer = [NSMutableString string];
    
    id tokenizer  = objc_msgSend(NSClassFromString(@"TDTokenizer"),NSSelectorFromString(@"tokenizerWithString:"),sourceString);
    objc_msgSend(objc_msgSend(tokenizer,NSSelectorFromString(@"whitespaceState")),NSSelectorFromString(@"setReportsWhitespaceTokens:"),YES);
    objc_msgSend(objc_msgSend(tokenizer,NSSelectorFromString(@"commentState")),NSSelectorFromString(@"setReportsCommentTokens:"),YES);
    
    id eof = objc_msgSend(NSClassFromString(@"TDToken"),NSSelectorFromString(@"EOFToken"));
    id tok = nil;
    id nextToken = nil;
    
    while ((tok = objc_msgSend(tokenizer,NSSelectorFromString(@"nextToken"))) != eof) {
        
        if (objc_msgSend(tok,NSSelectorFromString(@"isComment"))) {
            
            if([[tok stringValue] rangeOfString:@"/*"].location!=NSNotFound) {
                
                NSInteger numLines=[[tok stringValue] sdt_numberOfLines];
                NSMutableString* nastyComment=[NSMutableString string];
                for(int i=0;i<numLines;i++) {
                    [nastyComment appendString:(i<numLines-1) ? @"/* I will never ever remove block comments! (c) Gus Mueller :) */\n" : @"/* I will never ever remove block comments! (c) Gus Mueller :) */"];
                }
                [buffer appendString:nastyComment];
            }
            
        } else if (objc_msgSend(tok,NSSelectorFromString(@"isSymbol")) && [[tok stringValue] isEqualToString:@"@"]) {
            
            nextToken = objc_msgSend(tokenizer,NSSelectorFromString(@"nextToken"));
            if([nextToken valueForKey:@"quotedString"]) {
                [buffer appendFormat:@"[NSString stringWithString:%@]", [nextToken stringValue]];
            }
            else {
                [buffer appendString:[tok stringValue]];
                [buffer appendString:[nextToken stringValue]];
            }
        }
        else {
            [buffer appendString:[tok stringValue]];
        }
    }
    
    return buffer;
}

+(void)reportBrokenImport:(NSDictionary*)info {
    // FIXME: http://github.com/turbobabr/sketch-devtools/issues/20
    
    if([self sharedInstance].brokenImports==nil) {
        [self sharedInstance].brokenImports=[NSMutableArray array];
    }
    
    [[self sharedInstance].brokenImports addObject:info];
}

+(void)reportValidImport:(NSString*)importFilePath atFile:(NSString*)filePath atLine:(NSInteger)line {
    SketchConsole* shared=[self sharedInstance];
    if(shared.validImports==nil) {
        shared.validImports=[NSMutableDictionary dictionary];
    }
    
    if(shared.validImports[importFilePath]) {
        NSMutableDictionary* dict=shared.validImports[importFilePath];
        dict[@"count"]=@([dict[@"count"] integerValue]+1);
        [dict[@"imports"] addObject:@{ @"filePath":filePath, @"line":@(line) }];
    } else {
        shared.validImports[importFilePath]=[NSMutableDictionary dictionaryWithDictionary:
        @{
          @"count": @(1),
          @"imports" : [NSMutableArray arrayWithObject: @{ @"filePath":filePath, @"line":@(line) }]
          }];
    }
}

-(void)runScript:(NSString*)scriptSource {
    [[NSApp delegate] performSelector:NSSelectorFromString(@"runPluginScript:") withObject:scriptSource];
};


+(void)initFileWatchers {
    SketchConsole* shared=[self sharedInstance];
    NSString* rootPath=[[shared.scriptURL URLByDeletingLastPathComponent] path];
    NSArray* toObserve=@[@"index.html",@"consoleOptions.json",@"js",@"css",@"templates",@"changelog.json"];
    NSMutableArray* pathsToWatch=[NSMutableArray array];
    for(NSString* name in toObserve) {
        [pathsToWatch addObject:[NSString stringWithFormat:@"%@/%@",rootPath,name]];
    }
    shared.fileWatcher=[SDTFileWatcher fileWatcherWithPaths:pathsToWatch delegate:shared];
}

- (void)fileWatcherDidRecieveFSEvent:(SDTFileWatcher*)fw {
    [SketchConsole reloadWebView];
}

+(void)reloadWebView {
    WebView* webView=[self findWebView];
    if(webView==nil) {
        return;
    }
    
    SketchConsole* shared=[self sharedInstance];
    
    // Load web-page and initialize console.
    NSDictionary* files=[self getExternalFiles:shared.scriptURL];
    NSString* indexPageContents=[NSString stringWithContentsOfFile:[files[@"index"] path] encoding:NSUTF8StringEncoding error:nil];
    
    NSString* ts=[NSString stringWithFormat:@"?ts=%f",[[NSDate date] timeIntervalSince1970]];
    indexPageContents = [indexPageContents stringByReplacingOccurrencesOfString:@"?ts=NO_CACHE" withString:ts];
    
    [[webView mainFrame] loadHTMLString:indexPageContents baseURL:files[@"folder"]];
}

- (void)webView:(WebView *)sender didClearWindowObject:(WebScriptObject *)windowObject forFrame:(WebFrame *)frame {
    id win = [sender windowScriptObject];
    [win setValue:[[SketchConsole alloc] init] forKey:@"SketchDevTools"];
}

- (void)webView:(WebView *)sender didFinishLoadForFrame:(WebFrame *)frame {
    // FIXME: Why? :)
}


@end



#pragma clang diagnostic pop










