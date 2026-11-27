# DistribuPro Android app

This is a lightweight Android WebView wrapper for the existing DistribuPro website.
It uses the same website and Supabase backend; it does not create a separate database.

## Build an APK through GitHub Actions
1. Open the repository's **Actions** tab.
2. Select **Build DistribuPro Android APK**.
3. Choose **Run workflow** and run it on the main branch.
4. Open the completed workflow run and download the **DistribuPro-Android-debug** artifact.
5. Extract the ZIP and install `app-debug.apk` on your Android phone. Android may ask you to allow installation from that source.

The debug APK is for testing and is not a Play Store release. A Play Store release needs a signed release build and store setup.
