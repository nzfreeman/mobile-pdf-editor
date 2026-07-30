# google_mlkit_text_recognition references per-script recognizer option
# classes (Chinese/Japanese/Devanagari/Korean) generically, but only the
# scripts actually declared as dependencies are bundled (see app-level
# `text-recognition-korean` dependency for the script this app uses).
# Suppress R8's missing-class warnings for the script variants not used.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**

# ML Kit / Play Services rely on reflection internally; R8 stripping or
# renaming members it can't statically trace causes runtime NullPointerException
# ("getClass() on a null object reference") deep in obfuscated ML Kit
# internals. Keep everything under these packages untouched.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_text_common.** { *; }
-dontwarn com.google.mlkit.**
-dontwarn com.google.android.gms.**
