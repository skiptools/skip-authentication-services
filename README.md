# SkipAuthenticationServices

This module provides a compatibility API corresponding to Apple's [AuthenticationServices](https://developer.apple.com/documentation/AuthenticationServices) framework.

Currently, the framework provides the ability to launch a WebAuthenticationSession, which your app can use to authenticate a user using a web site. In the future, this framework will provide the ability to Sign In with Apple.

## Setup

To include this framework in your project, add the following dependency to your `Package.swift` file:

```swift
let package = Package(
    name: "my-package",
    products: [
        .library(name: "MyProduct", targets: ["MyTarget"]),
    ],
    dependencies: [
        .package(url: "https://source.skip.tools/skip-authentication-services.git", "0.0.0"..<"2.0.0"),
    ],
    targets: [
        .target(name: "MyTarget", dependencies: [
            .product(name: "SkipAuthenticationServices", package: "skip-authentication-services")
        ])
    ]
)
```

## Web Authentication Session

Your app can login using a web site you control using [`WebAuthenticationSession`](https://developer.apple.com/documentation/authenticationservices/webauthenticationsession). We support both the deprecated legacy iOS 16.4 API, [`authenticate(using:callbackURLScheme:preferredBrowserSession:)`](https://developer.apple.com/documentation/authenticationservices/webauthenticationsession/authenticate%28using:callbackurlscheme:preferredbrowsersession:%29), as well as the iOS 17.4 API, [`authenticate(using:callback:preferredBrowserSession:additionalHeaderFields:)`](https://developer.apple.com/documentation/authenticationservices/webauthenticationsession/authenticate%28using:callback:preferredbrowsersession:additionalheaderfields:%29).

First, you'll need to have a login page on a web site you control. When the user finishes logging in to the web site, your web site will need to redirect the user to a custom URL scheme. In other words, instead of sending the user to an URL starting with `https://` (the `https` is the "scheme" of the URL), you'll redirect the user to an URL starting with a scheme that you make up, e.g. `mycustomscheme://auth`. (Tip: Custom URL schemes can include dots, so you could use your app's bundle ID or Android package name, e.g. `com.example.myapp://auth`)

Your web site should pass an authentication token in a query parameter to the redirect URL, e.g. `com.example.myapp://auth?login_token=12345abcdef`. When the user signs in, `WebAuthenticationSession` will dismiss the login screen and return the URL containing the token. 

If you need to store the token securely, consider storing it in the user's keychain with the [skip-keychain](https://github.com/skiptools/skip-keychain) library.

```swift
#if os(Android)
import SkipAuthenticationServices
#else
import AuthenticationServices
#endif

import SwiftUI

struct ContentView: View {
    @Environment(\.webAuthenticationSession) var webAuthenticationSession: WebAuthenticationSession

    var body: some View {
        Button("Sign In") {
            Task {
                do {
                    let urlWithToken: URL
                    if #available(iOS 17.4, *) {
                        urlWithToken = try await webAuthenticationSession.authenticate(
                            using: URL(string: "https://example.com/login/")!,
                            callback: .customScheme("mycustomscheme"),
                            preferredBrowserSession: .ephemeral,
                            additionalHeaderFields: [:]
                        )
                    } else {
                        urlWithToken = try await webAuthenticationSession.authenticate(
                            using: URL(string: "https://example.com/login/")!,
                            callbackURLScheme: "mycustomscheme",
                            preferredBrowserSession: .ephemeral
                        )
                    }
                    let queryItems = URLComponents(url: urlWithToken, resolvingAgainstBaseURL: false)?.queryItems
                    let token = queryItems?.filter({ $0.name == "login_token" }).first?.value
                    
                    // Here, you can store the token (perhaps in the skip-keychain) and do something with it
                } catch {
                    if let error = error as? ASWebAuthenticationSessionError,
                       error.code == ASWebAuthenticationSessionError.canceledLogin {
                        print("user canceled login")
                    } else {
                        print("error: \(error)")
                    }
                }
            }
        }
    }
}
```

## Building

This project is a free Swift Package Manager module that uses the
[Skip](https://skip.tools) plugin to transpile Swift into Kotlin.

Building the module requires that Skip be installed using
[Homebrew](https://brew.sh) with `brew install skiptools/skip/skip`.
This will also install the necessary build prerequisites:
Kotlin, Gradle, and the Android build tools.

## Testing

The module can be tested using the standard `swift test` command
or by running the test target for the macOS destination in Xcode,
which will run the Swift tests as well as the transpiled
Kotlin JUnit tests in the Robolectric Android simulation environment.

Parity testing can be performed with `skip test`,
which will output a table of the test results for both platforms.

## License

This software is licensed under the
[GNU Lesser General Public License v3.0](https://spdx.org/licenses/LGPL-3.0-only.html),
with the following
[linking exception](https://spdx.org/licenses/LGPL-3.0-linking-exception.html)
to clarify that distribution to restricted environments (e.g., app stores) is permitted.

