# Aero for iPhone

A small native iPhone app that shows the Aero page your own server serves, in
a full-screen web view. It adds native pieces only where a web page cannot
reach on iOS. This is step 1: the shell. No server address is built in, and
none is stored in this repository.

## What it does now

- First launch shows one screen: a title, a field for the server's address,
  a Connect key and a line of help. The address may be typed with or without
  `https://`; `https://` is added when missing; plain `http://` is refused with
  a sentence saying so. The app asks the server for the address before saving
  it and says plainly when that fails (not found, not reachable, certificate
  not trusted, server error). The address is kept in `UserDefaults` (it is not
  a secret).
- Then opens that address edge to edge. The page handles its own safe areas
  and navigation. No pull to refresh, no native swipe gestures.
- Keeps sign-in cookies between launches (the persistent website data store).
- Lets the page use the camera and microphone for the entered host's origin
  only. Photo access uses the system picker. Usage texts are in `project.yml`.
- Plays audio inline without a tap where the page already plays it. Video
  still needs a tap, as in Safari.
- Adds `FingusAero/<version>` to the end of the user agent.
- Answers one message from the page, `{"ask":"about"}`, with the app version,
  build and the list of bridges (empty for now):
  `await window.webkit.messageHandlers.fingus.postMessage({ask:"about"})`.
  Only the entered host's main page may ask. In a browser that object does not
  exist, so the page can tell them apart.
- If the page cannot load, shows "Can't reach Aero" with "Try again" and
  "Change address" keys. "Change address" returns to the first-launch screen.
- Debug builds only: the web view can be inspected from Safari on a Mac.

### Which hosts stay in the app

The rule, in `AppInfo.staysInApp` and `WebViewController`:

1. A page on the entered host stays in the app.
2. So does a host in its family: the entered host without its first label
   when it has three or more labels (`app.example.com` gives `example.com`, so
   `login.example.com` stays); a two-label host or an IP address is its own
   family.
3. So does the host the web view is already showing, so a sign-in page on
   another host can submit its own forms and follow its own links.
4. A tapped link (or `window.open`) to any other host, and mail and phone
   links, open in Safari or the system.
5. Redirects, form posts and scripts that move the whole page stay in the app
   even to another host, so a sign-in that sends the page to another host and
   back works.

Why this and not a list: the server, not the app, decides where sign-in
happens, and the app cannot ask it. The page's own sign-in start sends the
browser to a separate sign-in host and back to the entered host, so rules 3
and 5 are what keep that working.

What could go wrong:

- Rule 2 is an approximation; there is no public suffix list in the app. For a
  host like `app.co.uk` the family is `co.uk`, so a tapped link to any other
  `.co.uk` site would open inside the app. It would not get camera or
  microphone: those are granted only to the entered host.
- Rule 5 trusts the server: a redirect or script on the server can move the
  page to any site, inside the app, with no address bar. Camera and microphone
  are still refused there.
- A sign-in on a host unrelated to the entered one that is reached by a
  *tapped link* (rather than a redirect) would open in Safari and its cookies
  would not reach the app.
- Whether WebKit calls the navigation policy for each server redirect with a
  type other than `linkActivated` is expected from its documented behaviour
  but is not tried here (see the unverified list).

## Building with no Mac

The Xcode project is not stored; `project.yml` describes it and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) generates it. A GitHub
Actions workflow (`.github/workflows/aero-ios.yml`) builds it on a macOS
runner. It starts only when you press Run workflow; it never runs on a push
or a schedule.

- Runner image `macos-15`, Xcode 26.2 chosen by path. The Xcode is pinned
  because the image's default Xcode (16.4 on the image listing read when this
  was written) is older than the SDK Apple asks for in uploads. The label
  `macos-15` is not a fixed image version: GitHub moves it to newer image
  versions, and the Xcode 26.2 path must still exist on them.
- Job `check`: installs XcodeGen with brew, generates, builds Debug for the
  iOS Simulator with signing off (`CODE_SIGNING_ALLOWED=NO`). It needs no
  Apple account. It prints how long it took, so the first build's time is
  measured.
- Job `testflight`: runs only if you tick `upload` and the secrets and
  variable below exist. It archives, signs through an App Store Connect API
  key (`-allowProvisioningUpdates -authenticationKeyPath ... -authenticationKeyID
  ... -authenticationKeyIssuerID ...`), uploads, and removes the key file. The
  build number is the run number. It prints its own duration.

### Settings (repository Settings, then Secrets and variables, then Actions)

| Name | Kind | Used for | If missing |
|---|---|---|---|
| `AERO_PRODUCT_NAME` | variable | the name on the phone | `Aero` |
| `AERO_BUNDLE_ID` | variable | the bundle identifier | `com.example.aero` |
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` | secrets | the upload | upload is skipped |
| `APPLE_TEAM_ID` | variable | the upload | upload is skipped |

The server address is not a build setting. To pre-fill the address field (for
a private build), set `AERO_DEFAULT_ADDRESS` in `project.yml`; it is empty by
default and the person can still change it.

The bundle identifier cannot be changed after the first upload to App Store
Connect. Settle it before uploading.

## Deployment target

iOS 16.4. It is the oldest version that has every API used here:
`WKWebView.isInspectable` (16.4), `requestMediaCapturePermissionFor` (15),
`WKScriptMessageHandlerWithReply` (14) and `async` `URLSession` calls (15).
Raise it in `project.yml` if you do not need older phones.

## How other self-hosted apps start

Read when this was written, to check the first-launch pattern:

- Home Assistant's iOS companion app searches the local network for servers,
  and otherwise offers "Enter address manually"
  (https://companion.home-assistant.io/docs/getting_started/).
- Nextcloud's iOS app has a Log in key, then a Server Address field and Next,
  then sign-in in a secure browser view (from search-result summaries, for
  example https://docs.start9.com/0.3.5.x/service-guides/nextcloud/nextcloud-setup/nextcloud-ios;
  the page itself was not opened).
- Jellyfin's Swiftfin app offers "Connect to Server" with a typed URL, a list
  of servers found on the local network, and Quick Connect (from search-result
  summaries, for example https://jellyfin.org/docs/general/server/quick-connect/;
  not opened).

This app uses the typed address only. Local-network discovery and a
sign-in step in the app are not built.

## For the App Store

What review needs that does not exist yet. Guideline numbers are from Apple's
App Review Guidelines (https://developer.apple.com/app-store/review/guidelines/,
read for this section). Nothing here is a promise of approval.

| Guideline | What it says, in short | State here |
|---|---|---|
| 4.2 Minimum functionality | "Your app should include features, content, and UI that elevate it beyond a repackaged website." Also 4.2.2: not primarily "a collection of links" or web clippings. | Today the app is the web view, an address screen and an unreachable screen. Nothing counts toward 4.2 beyond the web view. Planned native pieces that would add to it: notifications through APNs, calls that ring and carry on with the screen locked (CallKit), a share extension, real haptics, Keychain storage. None exist. |
| 2.1 App completeness | Include demo account information and "turn on your back-end service" if the app has a login; or, with Apple's prior approval, a built-in demo mode. | Missing. A reviewer cannot use the app without a server. A demo server the reviewer can reach, with a sign-in, is needed, or a built-in demo mode agreed with Apple first. |
| 5.1.1(i) Privacy policy | A privacy policy link in App Store Connect and in the app, saying what data is collected, how, retention and deletion. App Store Connect also asks the app privacy ("nutrition label") questions and a privacy policy URL for iOS (https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy). | Missing: no policy, no in-app link, no answers. What the app itself collects is the saved address and the web view's own cookies on the phone; what the server collects is the server operator's matter and would need stating. |
| 5.1.1(v) Account deletion | If the app supports account creation, it must offer account deletion in the app. | Not applicable to the app itself, which creates no account. If the page offers account creation, this depends on the page. |
| 1.2 User-generated content | Apps with user-generated content or social features need filtering, a way to report, a way to block abusive users and published contact information. | Needed if the page lets people message each other or see content others made. The page does have chat between accounts, so reporting, blocking and a contact address are needed in the page or the app. None are checked here. |
| 4.8 Login services | An app using a third-party or social login for its primary account must also offer an equivalent privacy-preserving login option. Not required if the app exclusively uses its own sign-in system. | The app has no sign-in of its own. If the server's page offers a third-party login, this applies; to be checked against the page. |
| Icon | An app icon is part of the build. | Missing: `Aero/Assets.xcassets/AppIcon.appiconset` is declared for one 1024 px universal icon and holds no image. Upload to App Store Connect is refused without one. |
| 2.3.3 Screenshots | "Screenshots should show the app in use, and not merely the title art, login page, or splash screen." At least one for iPhone with Dynamic Island, 1179 x 2556 or 1206 x 2622 px, no alpha (https://developer.apple.com/help/app-store-connect/reference/screenshot-specifications). | Missing. They need a server to show the app in use. |
| 2.3.6 Age rating | Answer the age rating questions honestly in App Store Connect. | Not answered. The answers depend on what the page shows. |
| Export compliance | Declare encryption use; `ITSAppUsesNonExemptEncryption` in Info.plist answers the question for each submission (https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance). | `project.yml` sets it to false, on the reading that the app uses only standard HTTPS from the operating system. Apple's page lists "standard encryption algorithms" and "crypto functionality within Apple's operating system" among what needs a determination, so whether false is right for this app is for the publisher to confirm. |
| 2.3.1 Notes for review | New features must be described with specificity in the Notes for Review. | To write when submitting. |

## Not done yet, in the order planned

1. Notifications. They need: an APNs key (token authentication, a `.p8` file
   from the developer account), a route on the server that stores the device
   token the app registers, the Push Notifications capability on the app
   identifier, and a paid Apple Developer Program membership. Web push does
   not reach a page inside an app.
2. Calls: first test whether the page's call keeps its audio with the screen
   locked inside the web view; add CallKit around it if so, native audio if not.
3. A share extension, real haptics, stickers and Genmoji, the Keychain. Each
   is a small bridge answered by `Bridge.swift`; the page does what it does
   now when the bridge is absent.

## Open items

- Licence: to be chosen by the owner.
- Name and bundle identifier: placeholders until you set the variables.
- App icon: see the table above.
- The page checks `navigator.standalone` to decide whether it runs as an
  installed web app; inside this app that is false, so the page may act as if
  it were in a browser. That is a page change, not an app change.
- Passkeys on the page's domain inside a web view need the Associated Domains
  capability, which is not added.

## What is not verified until a macOS build has run

The Swift was written on Linux and has never been compiled. Unverified:

- That all of the Swift compiles under Xcode 26.2 (every file), including the
  `async` address check and the `Task { @MainActor in ... }` block in
  `SetupView.swift`.
- That XcodeGen accepts `project.yml` as written, in particular the empty
  `UILaunchScreen: {}` dictionary, `$(AERO_DEFAULT_ADDRESS)` in
  `info: properties`, the `Aero/Info.plist` path inside the sources folder,
  and `ASSETCATALOG_COMPILER_APPICON_NAME` with an empty icon set.
- That the command-line build settings override the placeholders in
  `project.yml` as intended.
- That the signing flow, `ExportOptions.plist` and the upload work (they need
  an Apple account to be tried at all).
- On a real phone: that the address screen accepts and refuses what it should,
  that the page loads and keeps its sign-in, that a sign-in through another
  host works under the hosts rule above (WebKit calling the navigation policy
  for server redirects is the part relied on), that camera and microphone work
  for the entered host and are refused elsewhere, and that the user-agent
  token and the `about` reply arrive.
- That the error mapping in `AddressChecker` (which `URLError` codes arrive for
  a missing host or an untrusted certificate) matches what the phone reports.
- That the Xcode 26.2 path exists on the runner when the job is run.
- The Apple documentation pages for Swift API signatures render by script and
  were not read in full; names were checked against WebKit's public headers.
