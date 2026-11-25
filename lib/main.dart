import 'dart:async';

import 'package:flutter/material.dart';

import 'app.dart';
import 'dev/acceptance_trace.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (acceptanceTraceEnabled) unawaited(acceptanceTrace.start());
  runApp(const PhotoTreeApp());
}
