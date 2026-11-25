# Contributing to PhotoTree

Development and CI use Flutter 3.47.6 (Dart 3.13.5). Android builds also need JDK 17 and the Android SDK. Run `flutter doctor -v` to check your environment.

From the repository root, run:

```sh
flutter pub get
flutter analyze
flutter test
```

To try your change on an emulator, use the contributor debug build described in the [README](README.md#-platform-and-development). When testing operations that move or delete media, use an emulator library populated with disposable photos. These operations change the files in shared storage.

Open a pull request against `main`. Describe the behavior before and after your change and list the checks you ran. For changes to permissions, backups, or shared storage, describe what happens if the user cancels or access is denied. Keep each pull request focused on one change.
