// Copyright 2023–2026 Skip
// SPDX-License-Identifier: MPL-2.0
#if !SKIP_BRIDGE
#if canImport(AuthenticationServices)
@_exported import AuthenticationServices
#elseif SKIP
import Foundation
import SwiftUI
import OSLog
import androidx.browser.auth.AuthTabIntent
import androidx.browser.customtabs.CustomTabsCallback
import androidx.browser.customtabs.CustomTabsClient
import androidx.browser.customtabs.CustomTabsIntent
import androidx.browser.customtabs.CustomTabsServiceConnection
import androidx.activity.ComponentActivity
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.ActivityResultRegistry
import androidx.activity.result.ActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import android.net.Uri
import android.app.Activity
import android.os.Build
import android.app.Application
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import androidx.core.util.Consumer
import java.util.UUID
import kotlinx.coroutines.suspendCancellableCoroutine

let logger: Logger = Logger(subsystem: "skip.authentication-services", category: "SkipAuthenticationServices")

struct WebAuthenticationSessionEnvironmentKey: EnvironmentKey {
    static let defaultValue = WebAuthenticationSession()
}

extension EnvironmentValues {
    public var webAuthenticationSession: WebAuthenticationSession {
        get { self[WebAuthenticationSessionEnvironmentKey.self] }
        set { self[WebAuthenticationSessionEnvironmentKey.self] = newValue }
    }
}

public let ASWebAuthenticationSessionErrorDomain: String = "WebAuthenticationSession"

public struct ASWebAuthenticationSessionError: CustomNSError, Hashable, Error {
    public let code: Code
    
    public static var errorDomain: String {
        return ASWebAuthenticationSessionErrorDomain
    }
    
    public enum Code: Int, @unchecked Sendable, Equatable {
        case canceledLogin = 1
        case presentationContextNotProvided = 2
        case presentationContextInvalid = 3
    }
    
    public init(code: Code) {
        self.code = code
    }
    
    public static var canceledLogin: Code { .canceledLogin }
    public static var presentationContextNotProvided: Code { .presentationContextNotProvided }
    public static var presentationContextInvalid: Code { .presentationContextInvalid }
}

// SKIP @bridge
public struct WebAuthenticationSession {
    private enum FallbackAuthState {
        case readyToLaunch
        case launched
        case pausedAfterLaunch
        case completed
    }

    public enum BrowserSession {
        case ephemeral
        case shared
    }
    
    public enum Callback: @unchecked Sendable, Hashable {
        case customScheme(String)
        case https(host: String, path: String)
    }
    
    public func authenticate(
        using url: URL,
        callbackURLScheme: String,
        preferredBrowserSession: BrowserSession? = nil
    ) async throws -> URL {
        return try await authenticate(
            using: url,
            callback: .customScheme(callbackURLScheme),
            preferredBrowserSession: preferredBrowserSession,
            additionalHeaderFields: [:]
        )
    }
    
    public func authenticate(
        using url: URL,
        callback: Callback,
        preferredBrowserSession: BrowserSession? = nil,
        additionalHeaderFields: [String: String]
    ) async throws -> URL {
        // AuthTabIntent doesn't support passing additional header fields
        if !additionalHeaderFields.isEmpty {
            fatalError("Additional header fields are not supported in Skip")
        }
        
        guard let activity = UIApplication.shared.androidActivity else {
            throw ASWebAuthenticationSessionError(code: .presentationContextInvalid)
        }
        
        let preferredBrowserSession = preferredBrowserSession ?? .shared
        
        let androidUri = Uri.parse(url.absoluteString)
        
        let packageName = CustomTabsClient.getPackageName(activity, nil)
        let isAuthTabSupported = packageName != nil && CustomTabsClient.isAuthTabSupported(activity, packageName!)
        
        if isAuthTabSupported {
            let builder = AuthTabIntent.Builder()
            if preferredBrowserSession == .ephemeral {
                // Ephemeral Auth Tab browsing crashes Chrome on Android 8–9 (API 26–28); safe from API 29 onward.
                // https://issuetracker.google.com/issues/517208672
                let minSdkForEphemeralAuthTabBrowsing = 29
                if Int(Build.VERSION.SDK_INT) >= minSdkForEphemeralAuthTabBrowsing {
                    builder.setEphemeralBrowsingEnabled(true)
                } else {
                    logger.warning(
                        "Ephemeral Auth Tab browsing is disabled on Android API \(Build.VERSION.SDK_INT) (requires API \(minSdkForEphemeralAuthTabBrowsing)+); Chrome may crash if enabled. Using a shared browser session."
                    )
                }
            }
            let authTabIntent = builder.build()
            
            var launcher: ActivityResultLauncher<android.content.Intent>? = nil
            defer { launcher?.unregister() }
            
            return try await suspendCancellableCoroutine { continuation in
                let registry = activity.activityResultRegistry
                let uniqueKey = UUID.randomUUID().toString()
                let contract = ActivityResultContracts.StartActivityForResult()
                
                launcher = registry.register(uniqueKey, contract) { activityResult in
                    if activityResult.resultCode == Activity.RESULT_OK {
                        if let resultData = activityResult.data, let resultUri = resultData.data, let callbackURL = URL(string: resultUri.toString()) {
                            continuation.resumeWith(kotlin.Result.success(callbackURL))
                        } else {
                            let error = RuntimeException("WebAuthenticationSession invalid activity result data, should be a valid URL string, got: \(String(describing: activityResult.data))")
                            continuation.resumeWith(kotlin.Result.failure(error))
                        }
                    } else if activityResult.resultCode == Activity.RESULT_CANCELED {
                        let error = ASWebAuthenticationSessionError(code: .canceledLogin)
                        continuation.resumeWith(kotlin.Result.failure(error))
                    } else {
                        let error = RuntimeException("WebAuthenticationSession unknown result code: \(activityResult.resultCode)")
                        continuation.resumeWith(kotlin.Result.failure(error))
                    }
                }
                
                // Use the appropriate launch method based on callback type
                switch callback {
                case .customScheme(let callbackURLScheme):
                    authTabIntent.launch(launcher!, androidUri, callbackURLScheme)
                case .https(let redirectHost, let redirectPath):
                    authTabIntent.launch(launcher!, androidUri, redirectHost, redirectPath)
                }
            }
        } else {
            // Fallback to Custom Tabs

            // Custom Tabs cancellation is observed through multiple signals:
            // 1) A matching callback intent means authentication succeeded.
            // 2) If we can bind a Custom Tabs session, TAB_HIDDEN means user dismissed the tab.
            // 3) If we can't bind a session (e.g. because we don't have permission to query the
            //  custom tabs service), returning to this activity after launching the tab without
            //  receiving a callback intent is treated as cancel.
            var intentListener: CustomTabsIntentListener? = nil
            var lifecycleCallbacks: AuthenticationLifecycleCallbacks? = nil
            var customTabsConnection: CustomTabsSessionConnection? = nil
            defer {
                if let lifecycleCallbacks {
                    activity.application.unregisterActivityLifecycleCallbacks(lifecycleCallbacks)
                }
                if let listenerToRemove = intentListener {
                    activity.removeOnNewIntentListener(listenerToRemove)
                }
                if let connectionToUnbind = customTabsConnection {
                    activity.unbindService(connectionToUnbind)
                }
            }
            
            // Assert that the activity has an intent filter matching the callback URL scheme
            let testCallbackURL: String
            switch callback {
            case .customScheme(let scheme):
                // Use a minimal test URL - the host requirement will be checked by the intent filter
                testCallbackURL = "\(scheme)://auth"
            case .https(let redirectHost, let redirectPath):
                testCallbackURL = "https://\(redirectHost)\(redirectPath)"
            }
            
            let testIntent = Intent(Intent.ACTION_VIEW, Uri.parse(testCallbackURL))
            testIntent.addCategory(Intent.CATEGORY_BROWSABLE)
            testIntent.addCategory(Intent.CATEGORY_DEFAULT)
            
            let packageManager = activity.packageManager
            let resolveInfos = packageManager.queryIntentActivities(testIntent, PackageManager.MATCH_DEFAULT_ONLY)
            
            // Check if any resolved activity matches the current activity
            // activityInfo.name can be either fully qualified or relative (starting with .)
            let currentActivityName = activity.javaClass.name
            let currentActivitySimpleName = "." + activity.javaClass.simpleName
            let canHandleCallback = resolveInfos.any { resolveInfo in
                let resolvedName = resolveInfo.activityInfo.name
                resolveInfo.activityInfo.packageName == activity.packageName &&
                (resolvedName == currentActivityName || resolvedName == currentActivitySimpleName)
            }
            
            assert(canHandleCallback, "Activity \(currentActivityName) does not have an intent filter matching callback URL scheme. Expected URL: \(testCallbackURL). Add an intent-filter to AndroidManifest.xml with the matching scheme.")
            
            return try await suspendCancellableCoroutine { continuation in
                var fallbackAuthState: FallbackAuthState = .readyToLaunch
                
                let resumeOnce: (kotlin.Result<URL>) -> Void = { result in
                    guard fallbackAuthState != .completed else { return }
                    fallbackAuthState = .completed
                    continuation.resumeWith(result)
                }
                
                lifecycleCallbacks = AuthenticationLifecycleCallbacks(
                    onPaused: { pausedActivity in
                        if pausedActivity == activity, fallbackAuthState == .launched {
                            fallbackAuthState = .pausedAfterLaunch
                        }
                    },
                    onResumed: { resumedActivity in
                        if resumedActivity == activity, fallbackAuthState == .pausedAfterLaunch {
                            let error = ASWebAuthenticationSessionError(code: .canceledLogin)
                            resumeOnce(kotlin.Result.failure(error))
                        }
                    }
                )
                activity.application.registerActivityLifecycleCallbacks(lifecycleCallbacks!)
                
                intentListener = CustomTabsIntentListener { intent in
                    guard let dataString = intent.dataString, let callbackURL = URL(string: dataString) else {
                        logger.warning("launchCustomTab: callback intent had no valid URL: \(String(describing: intent.dataString))")
                        return
                    }
                    // Check if the URL matches our callback
                    switch callback {
                    case .customScheme(let scheme):
                        if callbackURL.scheme == scheme {
                            resumeOnce(kotlin.Result.success(callbackURL))
                        }
                    case .https(let redirectHost, let redirectPath):
                        if callbackURL.scheme == "https",
                           let host = callbackURL.host, host == redirectHost,
                           callbackURL.path == redirectPath {
                            resumeOnce(kotlin.Result.success(callbackURL))
                        }
                    default:
                        logger.warning("launchCustomTab: unknown callback URL: \(callbackURL)")
                        break
                    }
                }
                
                activity.addOnNewIntentListener(intentListener!)
                
                func launchCustomTab(_ customTabsSession: androidx.browser.customtabs.CustomTabsSession? = nil) {
                    guard fallbackAuthState == .readyToLaunch else { return }
                    fallbackAuthState = .launched
                    
                    let customTabsIntent: CustomTabsIntent
                    if let customTabsSession {
                        customTabsIntent = CustomTabsIntent.Builder(customTabsSession).build()
                    } else {
                        logger.warning("launchCustomTab: no custom tabs session")
                        customTabsIntent = CustomTabsIntent.Builder().build()
                    }
                    
                    customTabsIntent.intent.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    customTabsIntent.launchUrl(activity, androidUri)
                }
                
                guard let packageName else {
                    logger.warning("launchCustomTab: no CustomTabsClient package found, launching without session")
                    launchCustomTab()
                    return
                }

                let navigationCallback = CustomTabsNavigationCallback { navigationEvent in
                    if navigationEvent == CustomTabsCallback.TAB_HIDDEN {
                        let error = ASWebAuthenticationSessionError(code: .canceledLogin)
                        resumeOnce(kotlin.Result.failure(error))
                    }
                }
                
                let connection = CustomTabsSessionConnection(
                    onConnected: { client in
                        let customTabsSession = client.newSession(navigationCallback)
                        launchCustomTab(customTabsSession)
                    },
                    onDisconnected: { _ in
                        if fallbackAuthState == .readyToLaunch {
                            logger.warning("launchCustomTab: custom tabs service disconnected, launching without session")
                            launchCustomTab()
                        }
                    }
                )
                
                customTabsConnection = connection
                let didBindCustomTabsService = CustomTabsClient.bindCustomTabsService(activity, packageName, connection)
                if !didBindCustomTabsService {
                    logger.warning("launchCustomTab: failed to bind custom tabs service")
                    customTabsConnection = nil
                    launchCustomTab()
                }
            }
        }
    }
}

struct CustomTabsIntentListener : Consumer<Intent> {
    let onCallback: (Intent) -> Void
    
    override func accept(value: Intent) {
        if value.action == Intent.ACTION_VIEW {
            onCallback(value)
        }
    }
}

class CustomTabsNavigationCallback: CustomTabsCallback {
    let onNavigation: (Int) -> Void
    
    init(onNavigation: @escaping (Int) -> Void) {
        self.onNavigation = onNavigation
    }
    
    override func onNavigationEvent(navigationEvent: Int, extras: android.os.Bundle?) {
        onNavigation(navigationEvent)
    }
}

class CustomTabsSessionConnection: CustomTabsServiceConnection {
    let onConnected: (CustomTabsClient) -> Void
    let onDisconnected: (ComponentName) -> Void
    
    init(
        onConnected: @escaping (CustomTabsClient) -> Void,
        onDisconnected: @escaping (ComponentName) -> Void
    ) {
        self.onConnected = onConnected
        self.onDisconnected = onDisconnected
    }
    
    override func onCustomTabsServiceConnected(name: ComponentName, client: CustomTabsClient) {
        onConnected(client)
    }
    
    override func onServiceDisconnected(name: ComponentName) {
        onDisconnected(name)
    }
}

class AuthenticationLifecycleCallbacks: Application.ActivityLifecycleCallbacks {
    let onPaused: (Activity) -> Void
    let onResumed: (Activity) -> Void
    
    init(
        onPaused: @escaping (Activity) -> Void,
        onResumed: @escaping (Activity) -> Void
    ) {
        self.onPaused = onPaused
        self.onResumed = onResumed
    }
    
    override func onActivityPaused(activity: Activity) {
        onPaused(activity)
    }
    
    override func onActivityResumed(activity: Activity) {
        onResumed(activity)
    }
    
    override func onActivityCreated(activity: Activity, savedInstanceState: android.os.Bundle?) {}
    
    override func onActivityStarted(activity: Activity) {}
    
    override func onActivityStopped(activity: Activity) {}
    
    override func onActivitySaveInstanceState(activity: Activity, outState: android.os.Bundle) {}
    
    override func onActivityDestroyed(activity: Activity) {}
}
#endif
#else
import SkipSwiftUI

extension EnvironmentValues {
    public var webAuthenticationSession: WebAuthenticationSession {
        get { fatalError() }
        set { fatalError() }
    }
}

extension WebAuthenticationSession: @unchecked Sendable {}

#endif
