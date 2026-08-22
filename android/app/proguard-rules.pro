# NEk0 ProGuard/R8 rules.
#
# The app's Android code is a thin host (Activity + foreground service +
# notification receiver) driven by the Flutter engine and a Rust .so loaded
# via DynamicLibrary.open; no reflection-based lookup needs keep rules.
# Add project-specific -keep rules here if R8 shrinking ever strips
# something required at runtime.
