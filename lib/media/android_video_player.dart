import 'package:video_player/video_player.dart';

// contentUri is the Android adapter; playback and controls use the shared plugin.
VideoPlayerController androidVideoController(Uri uri) =>
    VideoPlayerController.contentUri(uri);
