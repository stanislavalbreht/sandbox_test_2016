{
  "targets": [
    {
      "target_name": "sb_test",
      "type": "executable",
      "sources": [
        "main.cc",
        "sandbox_init_mac.cc",
        "sandbox_init_mac.h",
        "sandbox_mac.h",
        "sandbox_mac.mm",
      ],
      "include_dirs": [
        "include",
      ],
      "dependencies": [
        "../base/base.gyp:base",
        "../sandbox/sandbox.gyp:sandbox",
        "../third_party/icu/icu.gyp:icuuc",
      ],
      'link_settings': {
        'libraries': [
          '$(SDKROOT)/System/Library/Frameworks/IOSurface.framework',
          '$(SDKROOT)/System/Library/Frameworks/QuartzCore.framework',
          '$(SDKROOT)/usr/lib/libsandbox.dylib',
        ],
      },
    }
  ]
}
