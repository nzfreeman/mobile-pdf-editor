# google_mlkit_text_recognition references per-script recognizer option
# classes (Chinese/Japanese/Devanagari/Korean) generically, but only the
# scripts actually declared as dependencies are bundled (see app-level
# `text-recognition-korean` dependency for the script this app uses).
# Suppress R8's missing-class warnings for the script variants not used.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**

# ML Kit's public API relies on reflection internally; keep it whole
# rather than risk R8 stripping/renaming something it can't statically
# trace back to a call site.
-keep class com.google.mlkit.** { *; }

# The actual release crash this file exists to prevent (NullPointerException,
# "getClass() on a null object reference", inside heavily-obfuscated frames
# like u3.ka/t3.q/q4.e/s4.a/b5.c/o3.e/j5.b) happened in Play Services'
# *internal* ML Kit glue code, not the public com.google.mlkit API surface —
# so keeping only that wouldn't have fixed it. Scope the Play Services keep
# to the internal packages ML Kit's task/model-loading plumbing actually
# uses, instead of all of com.google.android.gms.** (which also covers
# Maps/Ads/Auth/Analytics/etc. this app never touches, and keeping all of
# it defeats most of R8's size/optimization benefit for no reason).
-keep class com.google.android.gms.internal.mlkit_vision_text_common.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_text_bundled_common.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_common.** { *; }
-keep class com.google.android.gms.common.** { *; }
-keep class com.google.android.gms.tasks.** { *; }
-dontwarn com.google.mlkit.**
-dontwarn com.google.android.gms.**
