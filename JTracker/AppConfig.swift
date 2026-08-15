import Foundation

/// App-wide configuration values.
enum AppConfig {
    /// Your Supabase project URL, e.g. https://abcdxyz.supabase.co
    static let supabaseURL = "https://imiampamznvfdebbcoxk.supabase.co"

    /// Your Supabase **anon public** API key (safe to ship in the app; it's
    /// protected by Row Level Security policies on the database).
    static let supabaseAnonKey = "sb_publishable_T1Tx7-gPZ6R8H4jf5VcQUA_fvOVr9hR"

    // MARK: - Google (Gmail) OAuth

    /// iOS OAuth client ID. Not a secret — iOS clients ship it and use PKCE
    /// instead of a client secret.
    static let googleClientID = "893359004595-r6vvkbkonur3qmkv17nupi6na9t49749.apps.googleusercontent.com"

    /// The reversed client ID, used as the redirect URL scheme. Google
    /// auto-accepts this redirect for iOS clients, so no console setup is needed.
    static let googleRedirectScheme = "com.googleusercontent.apps.893359004595-r6vvkbkonur3qmkv17nupi6na9t49749"

    /// Full redirect URI handed to Google and matched on the callback.
    static var googleRedirectURI: String { "\(googleRedirectScheme):/oauth2redirect" }

    /// Requested scopes: identify the account (openid/email) and allow sending
    /// mail on the user's behalf later.
    static let googleScopes = "openid email https://www.googleapis.com/auth/gmail.send"
}
