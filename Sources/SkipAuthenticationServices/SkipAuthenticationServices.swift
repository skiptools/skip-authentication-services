// Copyright 2023–2025 Skip
// SPDX-License-Identifier: LGPL-3.0-only WITH LGPL-3.0-linking-exception
#if !SKIP_BRIDGE
#if SKIP
import Foundation
import SwiftUI
import androidx.browser.auth.AuthTabIntent
import androidx.activity.ComponentActivity
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.ActivityResultRegistry
import androidx.activity.result.ActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import android.net.Uri
import android.app.Activity
import android.content.Intent
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
    }
}
#endif
#endif
