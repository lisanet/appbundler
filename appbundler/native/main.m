/*
 * Copyright 2012, Oracle and/or its affiliates. All rights reserved.
 *
 * DO NOT ALTER OR REMOVE COPYRIGHT NOTICES OR THIS FILE HEADER.
 *
 * This code is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License version 2 only, as
 * published by the Free Software Foundation.  Oracle designates this
 * particular file as subject to the "Classpath" exception as provided
 * by Oracle in the LICENSE file that accompanied this code.
 *
 * This code is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
 * version 2 for more details (a copy is included in the LICENSE file that
 * accompanied this code).
 *
 * You should have received a copy of the GNU General Public License version
 * 2 along with this work; if not, write to the Free Software Foundation,
 * Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301 USA.
 *
 * Please contact Oracle, 500 Oracle Parkway, Redwood Shores, CA 94065 USA
 * or visit www.oracle.com if you need additional information or have any
 * questions.
 */

#import <Cocoa/Cocoa.h>
#include <dlfcn.h>
#include <jni.h>
#include <stdlib.h>

#define JAVA_LAUNCH_ERROR "JavaLaunchError"

#define JVM_RUNTIME_KEY "JVMRuntime"
#define WORKING_DIR "WorkingDirectory"
#define JVM_MAIN_CLASS_NAME_KEY "JVMMainClassName"
#define JVM_OPTIONS_KEY "JVMOptions"
#define JVM_DEFAULT_OPTIONS_KEY "JVMDefaultOptions"
#define JVM_ARGUMENTS_KEY "JVMArguments"
#define JVM_CLASSPATH_KEY "JVMClassPath"
#define JVM_VERSION_KEY "JVMVersion"
#define JVM_VERSION_EXACT_KEY "JVMExact"
#define JVM_DEBUG_KEY "JVMDebug"

#define JVM_RUN_PRIVILEGED "JVMRunPrivileged"

#define UNSPECIFIED_ERROR "An unknown error occurred."

#define APP_ROOT_PREFIX "$APP_ROOT"

#define JRE_JAVA "/Library/Internet Plug-Ins/JavaAppletPlugin.plugin/Contents/Home/bin/java"
#define JRE_DYLIB "/Library/Internet Plug-Ins/JavaAppletPlugin.plugin/Contents/Home/lib/jli/libjli.dylib"

typedef int (JNICALL *JLI_Launch_t)(int argc, char ** argv,
                                    int jargc, const char** jargv,
                                    int appclassc, const char** appclassv,
                                    const char* fullversion,
                                    const char* dotversion,
                                    const char* pname,
                                    const char* lname,
                                    jboolean javaargs,
                                    jboolean cpwildcard,
                                    jboolean javaw,
                                    jint ergo);

static char** progargv = NULL;
static int progargc = 0;
static int launchCount = 0;

int launch(char *, int, char **);
NSString * findDylib (NSString *, bool);
NSString * convertRelativeFilePath(NSString * path);

int main(int argc, char *argv[]) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    int result;
    @try {
    	if ((argc > 1) && (launchCount == 0)) {
    		progargc = argc - 1;
    		progargv = &argv[1];
    	}

        launch(argv[0], progargc, progargv);
        result = 0;
    } @catch (NSException *exception) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setAlertStyle:NSCriticalAlertStyle];
        [alert setMessageText:[exception reason]];
      
        if ([[exception name] isEqualToString: @"NoJREError"]) {
          [alert addButtonWithTitle: NSLocalizedString(@"Load", nil)];
          [alert addButtonWithTitle: NSLocalizedString(@"Cancel", nil)];
          [alert setInformativeText: NSLocalizedString(@"NoJREInfo", @"click to go to website of JRE")];
        
          result = [alert runModal];
          if (result == NSAlertFirstButtonReturn) {
            [[NSWorkspace sharedWorkspace] openURL: [NSURL URLWithString: @"https://aws.amazon.com/de/corretto/"]];
            result = 0;
          }
          
        } else {
          [alert runModal];
          result = 1;
        }
    }

    [pool drain];

    return result;
}

int launch(char *commandName, int progargc, char *progargv[]) {
    // Get the main bundle
    NSBundle *mainBundle = [NSBundle mainBundle];

    // Get the main bundle's info dictionary
    NSDictionary *infoDictionary = [mainBundle infoDictionary];
    
    // Test for debugging (but only on the second runthrough)
    bool isDebugging = (launchCount > 0) && [[infoDictionary objectForKey:@JVM_DEBUG_KEY] boolValue];
	
    if (isDebugging) {
        NSLog(@"Loading Application '%@'", [infoDictionary objectForKey:@"CFBundleName"]);
    }
    
    // Set the working directory based on config, defaulting to the user's home directory
    NSString *workingDir = [infoDictionary objectForKey:@WORKING_DIR];
    if (workingDir != nil) {
        workingDir = [workingDir stringByReplacingOccurrencesOfString:@APP_ROOT_PREFIX withString:[mainBundle bundlePath]];
    } else {
        workingDir = NSHomeDirectory();
    }
    if (isDebugging) {
    	NSLog(@"Working Directory: '%@'", convertRelativeFilePath(workingDir));
    }
    
    chdir([workingDir UTF8String]);
           
    // execute privileged
    NSString *privileged = [infoDictionary objectForKey:@JVM_RUN_PRIVILEGED];
    if ( privileged != nil && getuid() != 0 ) {
        NSDictionary *error = [NSDictionary new];
        NSString *script =  [NSString stringWithFormat:@"do shell script \"\\\"%@\\\" > /dev/null 2>&1 &\" with administrator privileges", [NSString stringWithCString:commandName encoding:NSASCIIStringEncoding]];
        NSAppleScript *appleScript = [[NSAppleScript new] initWithSource:script];
        if ([appleScript executeAndReturnError:&error]) {
            // This means we successfully elevated the application and can stop in here.
            return 0;
        }
    }
	
	// what java version is required
    NSString *jvm_version;
    NSString *java_version;
    BOOL jvm_exact = NO;
    
	java_version = [infoDictionary objectForKey:@JVM_VERSION_KEY];
    if (java_version == nil) {
        java_version = @"8";  // minumum is Java 8
    }
    // remove a potentila 1.x from the version string, so that java_version is alway an int to be better read in a message box
    if ([java_version hasPrefix:@"1."]) {
        java_version = [java_version substringFromIndex: 3];
    }
	if ([java_version integerValue] < 9) {
		jvm_version = [NSString stringWithFormat: @"1.%@", java_version] ;
    } else {
        jvm_version = java_version;
    }
    // check if we require the exact Java version
    jvm_exact = [[infoDictionary objectForKey: @JVM_VERSION_EXACT_KEY] boolValue];
    if (!jvm_exact) {
        jvm_version = [java_version stringByAppendingString: @"+"];
    }
    
	
    // Locate the JLI_Launch() function
    NSString *runtime = [infoDictionary objectForKey:@JVM_RUNTIME_KEY];
    
    NSString *javaDylib;
    NSString *runtimePath = [[mainBundle builtInPlugInsPath] stringByAppendingPathComponent:runtime];
    if (runtime != nil)
    {
        javaDylib = [runtimePath stringByAppendingPathComponent:@"Content/Home/lib/jli/libjli.dylib"];
    }
    else
    {
        javaDylib = findDylib (jvm_version, isDebugging);
    }
    if (isDebugging) {
        NSLog(@"Java Runtime Path (relative): '%@'", runtimePath);
        NSLog(@"Java Runtime Dylib Path: '%@'", convertRelativeFilePath(javaDylib));
    }

    const char *libjliPath = NULL;
    if (javaDylib != nil)
    {
        libjliPath = [javaDylib fileSystemRepresentation];
    }
	
    void *libJLI = dlopen(libjliPath, RTLD_LAZY);

    JLI_Launch_t jli_LaunchFxnPtr = NULL;
    if (libJLI != NULL) {
        jli_LaunchFxnPtr = dlsym(libJLI, "JLI_Launch");
    }

    if (jli_LaunchFxnPtr == NULL) {
      [[NSException exceptionWithName: @"NoJREError"
                               reason: [NSString stringWithFormat: NSLocalizedString(@"needsJRE %@", @"Need to download JRE"),  java_version]
                             userInfo: nil] raise];
    }

    // Get the main class name
    NSString *mainClassName = [infoDictionary objectForKey:@JVM_MAIN_CLASS_NAME_KEY];
    if (mainClassName == nil) {
        [[NSException exceptionWithName:@JAVA_LAUNCH_ERROR
            reason:NSLocalizedString(@"MainClassNameRequired", @UNSPECIFIED_ERROR)
            userInfo:nil] raise];
    }

    // Set the class path
    NSString *mainBundlePath = [mainBundle bundlePath];

    // make sure the bundle path does not contain a colon, as that messes up the java.class.path,
    // because colons are used a path separators and cannot be escaped.

    // funny enough, Finder does not let you create folder with colons in their names,
    // but when you create a folder with a slash, e.g. "audio/video", it is accepted
    // and turned into... you guessed it, a colon:
    // "audio:video"
    if ([mainBundlePath rangeOfString:@":"].location != NSNotFound) {
        [[NSException exceptionWithName:@JAVA_LAUNCH_ERROR
            reason:NSLocalizedString(@"BundlePathContainsColon", @UNSPECIFIED_ERROR)
            userInfo:nil] raise];
    }

    NSString *javaPath = [mainBundlePath stringByAppendingString:@"/Contents/Java"];
    NSMutableString *classPath = [NSMutableString stringWithString:@"-Djava.class.path="];

    NSArray *cp = [infoDictionary objectForKey:@JVM_CLASSPATH_KEY];
    if (cp == nil) {
        
        // Implicit classpath, so use the contents of the "Java" folder to build an explicit classpath
        
        [classPath appendFormat:@"%@/Classes", javaPath];
        NSFileManager *defaultFileManager = [NSFileManager defaultManager];
        NSArray *javaDirectoryContents = [defaultFileManager contentsOfDirectoryAtPath:javaPath error:nil];
        if (javaDirectoryContents == nil) {
            [[NSException exceptionWithName:@JAVA_LAUNCH_ERROR
                reason:NSLocalizedString(@"JavaDirectoryNotFound", @UNSPECIFIED_ERROR)
                userInfo:nil] raise];
        }

        for (NSString *file in javaDirectoryContents) {
            if ([file hasSuffix:@".jar"]) {
                [classPath appendFormat:@":%@/%@", javaPath, file];
            }
        }
        
    } else {
        
        // Explicit ClassPath

        int k = 0;
        for (NSString *file in cp) {
            if (k++ > 0) [classPath appendString:@":"]; // add separator if needed
            file = [file stringByReplacingOccurrencesOfString:@APP_ROOT_PREFIX withString:[mainBundle bundlePath]];
            [classPath appendString:file];
        }
    }
    
    // Set the library path
    NSString *libraryPath = [NSString stringWithFormat:@"-Djava.library.path=%@/Contents/MacOS", mainBundlePath];

    // Get the VM options
    NSArray *options = [infoDictionary objectForKey:@JVM_OPTIONS_KEY];
    if (options == nil) {
        options = [NSArray array];
    }

    // Get the VM default options
    NSArray *defaultOptions = [NSArray array];
    NSDictionary *defaultOptionsDict = [infoDictionary objectForKey:@JVM_DEFAULT_OPTIONS_KEY];
    if (defaultOptionsDict != nil) {
        NSMutableDictionary *defaults = [NSMutableDictionary dictionaryWithDictionary: defaultOptionsDict];
        // Replace default options with user specific options, if available
        NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
        // Create special key that should be used by Java's java.util.Preferences impl
        // Requires us to use "/" + bundleIdentifier.replace('.', '/') + "/JVMOptions/" as node on the Java side
        // Beware: bundleIdentifiers shorter than 3 segments are placed in a different file!
        // See java/util/prefs/MacOSXPreferences.java of OpenJDK for details
        NSString *bundleDictionaryKey = [mainBundle bundleIdentifier];
        bundleDictionaryKey = [bundleDictionaryKey stringByReplacingOccurrencesOfString:@"." withString:@"/"];
        bundleDictionaryKey = [NSString stringWithFormat: @"/%@/", bundleDictionaryKey];

        NSDictionary *bundleDictionary = [userDefaults dictionaryForKey: bundleDictionaryKey];
        if (bundleDictionary != nil) {
            NSDictionary *jvmOptionsDictionary = [bundleDictionary objectForKey: @"JVMOptions/"];
            for (NSString *key in jvmOptionsDictionary) {
                NSString *value = [jvmOptionsDictionary objectForKey:key];
                [defaults setObject: value forKey: key];
            }
        }
        defaultOptions = [defaults allValues];
    }

    // Get the application arguments
    NSArray *arguments = [infoDictionary objectForKey:@JVM_ARGUMENTS_KEY];
    if (arguments == nil) {
        arguments = [NSArray array];
    }

    // Set OSX special folders
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory,   
            NSUserDomainMask, YES);                                            
    NSString *basePath = [paths objectAtIndex:0];                                                                           
    NSString *libraryDirectory = [NSString stringWithFormat:@"-DLibraryDirectory=%@", basePath];
    NSString *containersDirectory = [basePath stringByAppendingPathComponent:@"Containers"];
    NSString *sandboxEnabled = @"false";
    BOOL isDir;
    NSFileManager *fm = [[NSFileManager alloc] init];
    BOOL containersDirExists = [fm fileExistsAtPath:containersDirectory isDirectory:&isDir];
    if (containersDirExists && isDir) {
        sandboxEnabled = @"true";
    }
    NSString *sandboxEnabledVar = [NSString stringWithFormat:@"-DSandboxEnabled=%@", sandboxEnabled];
    
    paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,           
            NSUserDomainMask, YES);                                            
    basePath = [paths objectAtIndex:0];                                                                           
    NSString *documentsDirectory = [NSString stringWithFormat:@"-DDocumentsDirectory=%@", basePath];
                                                                               
    paths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, 
            NSUserDomainMask, YES);                                            
    basePath = [paths objectAtIndex:0];                                                                           
    NSString *applicationSupportDirectory = [NSString stringWithFormat:@"-DApplicationSupportDirectory=%@", basePath];
                                                                               
    paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, 
            NSUserDomainMask, YES);                                            
    basePath = [paths objectAtIndex:0];                                                                           
    NSString *cachesDirectory = [NSString stringWithFormat:@"-DCachesDirectory=%@", basePath];

    // Initialize the arguments to JLI_Launch()
    // +5 due to the special directories and the sandbox enabled property
    int argc = 1 + [options count] + [defaultOptions count] + 2 + [arguments count] + 1 + 5 + progargc;
    char *argv[argc];

    int i = 0;
    argv[i++] = commandName;
    argv[i++] = strdup([classPath UTF8String]);
    argv[i++] = strdup([libraryPath UTF8String]);
    argv[i++] = strdup([libraryDirectory UTF8String]);
    argv[i++] = strdup([documentsDirectory UTF8String]);
    argv[i++] = strdup([applicationSupportDirectory UTF8String]);
    argv[i++] = strdup([cachesDirectory UTF8String]);
    argv[i++] = strdup([sandboxEnabledVar UTF8String]);

    for (NSString *option in options) {
        option = [option stringByReplacingOccurrencesOfString:@APP_ROOT_PREFIX withString:[mainBundle bundlePath]];
        argv[i++] = strdup([option UTF8String]);
    }

    for (NSString *defaultOption in defaultOptions) {
        defaultOption = [defaultOption stringByReplacingOccurrencesOfString:@APP_ROOT_PREFIX withString:[mainBundle bundlePath]];
        argv[i++] = strdup([defaultOption UTF8String]);
    }

    argv[i++] = strdup([mainClassName UTF8String]);

    for (NSString *argument in arguments) {
        argument = [argument stringByReplacingOccurrencesOfString:@APP_ROOT_PREFIX withString:[mainBundle bundlePath]];
        argv[i++] = strdup([argument UTF8String]);
    }

	for (int ctr = 0; ctr < progargc; ctr++) {
		argv[i++] = progargv[ctr];
	}
    
    // Print the full command line for debugging purposes...
    if (isDebugging) {
        NSLog(@"Command line passed to application:");
        for( int j=0; j<i; j++) {
            NSLog(@"Arg %d: '%s'", j, argv[j]);
        }
    }

	launchCount++;

    // Invoke JLI_Launch()
    return jli_LaunchFxnPtr(argc, argv,
                            0, NULL,
                            0, NULL,
                            "",
                            "",
                            "java",
                            "java",
                            FALSE,
                            FALSE,
                            FALSE,
                            0);
}

/**
 *  Searches for a JRE, and failing that looks for a JDK.
 */
NSString * findDylib (NSString *java_version, bool isDebugging)
{
    NSString *javaDylib = nil;
	NSString *javahome = nil;
	NSString *testfile = nil;
	
    if (isDebugging) { NSLog (@"Searching for Java %@", java_version); }
	
	if (!system("/usr/libexec/java_home"))
	{
		NSString *command = [NSString stringWithFormat:@"/usr/libexec/java_home -Fv %@ > /tmp/java_home", java_version];
		system([command UTF8String]);
		javahome = [NSString stringWithContentsOfFile: @"/tmp/java_home"
											 encoding: NSUTF8StringEncoding
												error: NULL];
		
		// now test for a JRE
		javahome = [javahome stringByReplacingOccurrencesOfString:@"\n" withString:@""];
		testfile = [javahome stringByAppendingString: @"/jre/lib/jli/libjli.dylib"];
		if ([[NSFileManager defaultManager] fileExistsAtPath: testfile]) {
			javaDylib = testfile;
		} else {
			javaDylib = [javahome stringByAppendingString: @"/lib/jli/libjli.dylib"];
		}
	}
	
    return javaDylib;
}


NSString * convertRelativeFilePath(NSString * path) {
    return [path stringByStandardizingPath];
}
