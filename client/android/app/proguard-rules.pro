# The Flutter ML Kit plugin supports multiple scripts, but this app bundles
# only Japanese to keep the offline APK small. The unused optional APIs are
# referenced by the plugin's dispatch code and must not fail R8 analysis.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.korean.**
