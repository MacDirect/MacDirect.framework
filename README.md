# MacDirect.framework

MacDirect.framework is the client-side library for integrating the MacDirect update system into your macOS applications. It handles update checking, downloading, and installation with built-in support for Sandboxed apps.

## Features

- **Easy Integration**: Simple one-line configuration.
- **Sandbox Support**: Uses a dedicated helper tool to safely install updates in sandboxed environments.
- **Built-in UI**: Standardized update alerts and progress indicators.
- **Secure**: Verifies code signatures and checksums before installation.

## Installation

Add this framework to your Xcode project as a Swift Package or by embedding the framework directly.

## Usage

### Configuration

In your `AppDelegate` or `@main` App struct:

```swift
import MacDirect

func applicationDidFinishLaunching(_ notification: Notification) {
    MacDirect.configure(feedURL: "https://your-server.com/app-updates.json")
    MacDirect.presentUpdateProfileIfAvailable()
}
```

### Manual Check

```swift
MacDirect.checkForUpdatesManually()
```

## Internal Components

- **Update Engine**: Core logic for checking, downloading, and patching.
- **MacDirectSecurity**: Verifies the integrity of downloaded updates.
- **UI**: SwiftUI views for update notifications.
- **UpdateHelper**: A helper tool for performing installations, especially for Sandboxed applications.
