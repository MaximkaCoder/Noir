package app.noir.noir

import android.content.Context
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine

// audio_service shares one FlutterEngine between the activity and its
// playback service, so the activity extends its base class.
class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Optional local-only modules (see tool/run.ps1) hook in here when
        // they are built in; the public build has none.
        try {
            Class.forName("app.noir.noir.LocalOnlyModules")
                .getMethod("register", FlutterEngine::class.java, Context::class.java)
                .invoke(null, flutterEngine, applicationContext)
        } catch (_: ClassNotFoundException) {
        }
    }
}
