import ThumbFreeApp

// ThumbFree in the menu bar. The app is ThumbFreeApp's AppController (docs/mac.md, phase 3); this only starts it.
MainActor.assumeIsolated {
    AppController.run()
}
