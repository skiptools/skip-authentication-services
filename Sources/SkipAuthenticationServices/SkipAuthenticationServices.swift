// Copyright 2023–2026 Skip
// SPDX-License-Identifier: MPL-2.0
#if !SKIP_BRIDGE
#if SKIP
import Foundation
import SwiftUI
import androidx.browser.auth.AuthTabIntent
import androidx.browser.customtabs.CustomTabsClient
import androidx.browser.customtabs.CustomTabsIntent
import androidx.activity.ComponentActivity
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.ActivityResultRegistry
import androidx.activity.result.ActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import android.net.Uri
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import androidx.core.util.Consumer
import java.util.UUID
import kotlinx.coroutines.suspendCancellableCoroutine

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
                builder.setEphemeralBrowsingEnabled(true)
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
            var listener: CustomTabsIntentListener? = nil
            defer {
                let listenerToRemove = listener
                if let listenerToRemove = listenerToRemove {
                    activity.removeOnNewIntentListener(listenerToRemove)
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
                let createdListener = CustomTabsIntentListener { intent in
                    if let dataString = intent.dataString, let callbackURL = URL(string: dataString) {
                        // Check if the URL matches our callback
                        switch callback {
                        case .customScheme(let scheme):
                            if callbackURL.scheme == scheme {
                                continuation.resumeWith(kotlin.Result.success(callbackURL))
                            }
                        case .https(let redirectHost, let redirectPath):
                            if callbackURL.scheme == "https",
                               let host = callbackURL.host, host == redirectHost,
                               callbackURL.path == redirectPath {
                                continuation.resumeWith(kotlin.Result.success(callbackURL))
                            }
                        }
                    }
                }
                
                listener = createdListener
                activity.addOnNewIntentListener(createdListener)
                
                let customTabsIntent = CustomTabsIntent.Builder().build()
                customTabsIntent.intent.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                customTabsIntent.launchUrl(activity, androidUri)
            }
        }
    }
}

struct CustomTabsIntentListener : Consumer<Intent> {
    let onCallback: (Intent) -> Void
    
    override func accept(value: Intent) {
        android.util.Log.d("CustomTabsIntentListener", "accept: \(value)")
        if value.action == Intent.ACTION_VIEW {
            onCallback(value)
        }
    }
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
