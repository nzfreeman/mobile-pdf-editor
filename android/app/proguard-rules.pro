# google_mlkit_text_recognition references per-script recognizer option
# classes (Chinese/Japanese/Devanagari/Korean) generically, but only the
# scripts actually declared as dependencies are bundled (see app-level
# `text-recognition-korean` dependency for the script this app uses).
# Suppress R8's missing-class warnings for the script variants not used.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
