package app.noir.noir

import com.ryanheise.audioservice.AudioServiceActivity

// audio_service shares one FlutterEngine between the activity and its
// playback service, so the activity extends its base class.
class MainActivity : AudioServiceActivity()
