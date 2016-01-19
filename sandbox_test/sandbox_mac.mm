// Copyright (c) 2012 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "sandbox_test/sandbox_mac.h"

#import <Cocoa/Cocoa.h>
#include <stddef.h>
#include <stdint.h>

#include <CoreFoundation/CFTimeZone.h>
extern "C" {
#include <sandbox.h>
}
#include <signal.h>
#include <sys/param.h>

#include "base/command_line.h"
#include "base/compiler_specific.h"
#include "base/files/file_util.h"
#include "base/files/scoped_file.h"
#include "base/mac/bundle_locations.h"
#include "base/mac/foundation_util.h"
#include "base/mac/mac_util.h"
#include "base/mac/scoped_cftyperef.h"
#include "base/mac/scoped_nsautorelease_pool.h"
#include "base/mac/scoped_nsobject.h"
#include "base/macros.h"
#include "base/rand_util.h"
#include "base/strings/string16.h"
#include "base/strings/string_piece.h"
#include "base/strings/string_split.h"
#include "base/strings/string_util.h"
#include "base/strings/stringprintf.h"
#include "base/strings/sys_string_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "base/sys_info.h"
#include "third_party/icu/source/common/unicode/uchar.h"

extern "C" {
void CGSSetDenyWindowServerConnections(bool);
void CGSShutdownServerConnections();

void* sandbox_create_params();
int sandbox_set_param(void* params, const char* key, const char* value);
void* sandbox_compile_string(const char* profile_str,
                             void* params,
                             char** error);
int sandbox_apply(void* profile);
void sandbox_free_params(void* params);
void sandbox_free_profile(void* profile);
};

namespace {

// Is the sandbox currently active.
bool gSandboxIsActive = false;

// This is the internal definition of the structure used by sandbox parameters
// on OS X 10.6.
struct SandboxParams {
  void* buf;
  size_t count;
  size_t size;
};

// Try to escape |c| as a "SingleEscapeCharacter" (\n, etc).  If successful,
// returns true and appends the escape sequence to |dst|.
bool EscapeSingleChar(char c, std::string* dst) {
  const char *append = NULL;
  switch (c) {
    case '\b':
      append = "\\b";
      break;
    case '\f':
      append = "\\f";
      break;
    case '\n':
      append = "\\n";
      break;
    case '\r':
      append = "\\r";
      break;
    case '\t':
      append = "\\t";
      break;
    case '\\':
      append = "\\\\";
      break;
    case '"':
      append = "\\\"";
      break;
  }

  if (!append) {
    return false;
  }

  dst->append(append);
  return true;
}

// Errors quoting strings for the Sandbox profile are always fatal, report them
// in a central place.
NOINLINE void FatalStringQuoteException(const std::string& str) {
  // Copy bad string to the stack so it's recorded in the crash dump.
  char bad_string[256] = {0};
  base::strlcpy(bad_string, str.c_str(), arraysize(bad_string));
  DLOG(FATAL) << "String quoting failed " << bad_string;
}

}  // namespace

SandboxCompiler::SandboxCompiler(const std::string& profile_str)
    : params_map_(), profile_str_(profile_str) {
}

SandboxCompiler::~SandboxCompiler() {
}

bool SandboxCompiler::InsertBooleanParam(const std::string& key, bool value) {
  return params_map_.insert(std::make_pair(key, value ? "TRUE" : "FALSE"))
      .second;
}

bool SandboxCompiler::InsertStringParam(const std::string& key,
                                        const std::string& value) {
  return params_map_.insert(std::make_pair(key, value)).second;
}

void SandboxCompiler::FreeSandboxResources(void* profile,
                                           void* params,
                                           char* error) {
  if (error)
    sandbox_free_error(error);
  if (params)
    sandbox_free_params(params);
  if (profile)
    sandbox_free_profile(profile);
}

bool SandboxCompiler::CompileAndApplyProfile(std::string* error) {
  char* error_internal = nullptr;
  void* profile = nullptr;
  void* params = nullptr;

  if (!params_map_.empty()) {
    if (base::mac::IsOSSnowLeopard()) {
      // This is a workaround for 10.6, see crbug.com/509114.
      // Check that there is no integer overflow.
      base::CheckedNumeric<size_t> checked_size = params_map_.size();
      checked_size *= 2;
      if (!checked_size.IsValid())
        return false;

      SandboxParams* internal_params =
          static_cast<SandboxParams*>(malloc(sizeof(SandboxParams)));
      internal_params->buf = calloc(checked_size.ValueOrDie(), sizeof(void*));
      internal_params->count = 0;
      internal_params->size = checked_size.ValueOrDie();
      params = internal_params;
    } else {
      params = sandbox_create_params();
      if (!params)
        return false;
    }

    for (const auto& kv : params_map_)
      sandbox_set_param(params, kv.first.c_str(), kv.second.c_str());
  }

  profile =
      sandbox_compile_string(profile_str_.c_str(), params, &error_internal);
  if (!profile) {
    error->assign(error_internal);
    FreeSandboxResources(profile, params, error_internal);
    return false;
  }

  int result = sandbox_apply(profile);
  FreeSandboxResources(profile, params, error_internal);
  return result == 0;
}

// static
bool Sandbox::QuotePlainString(const std::string& src_utf8, std::string* dst) {
  dst->clear();

  const char* src = src_utf8.c_str();
  int32_t length = src_utf8.length();
  int32_t position = 0;
  while (position < length) {
    UChar32 c;
    U8_NEXT(src, position, length, c);  // Macro increments |position|.
    DCHECK_GE(c, 0);
    if (c < 0)
      return false;

    if (c < 128) {  // EscapeSingleChar only handles ASCII.
      char as_char = static_cast<char>(c);
      if (EscapeSingleChar(as_char, dst)) {
        continue;
      }
    }

    if (c < 32 || c > 126) {
      // Any characters that aren't printable ASCII get the \u treatment.
      unsigned int as_uint = static_cast<unsigned int>(c);
      base::StringAppendF(dst, "\\u%04X", as_uint);
      continue;
    }

    // If we got here we know that the character in question is strictly
    // in the ASCII range so there's no need to do any kind of encoding
    // conversion.
    dst->push_back(static_cast<char>(c));
  }
  return true;
}

// static
bool Sandbox::QuoteStringForRegex(const std::string& str_utf8,
                                  std::string* dst) {
  // Characters with special meanings in sandbox profile syntax.
  const char regex_special_chars[] = {
    '\\',

    // Metacharacters
    '^',
    '.',
    '[',
    ']',
    '$',
    '(',
    ')',
    '|',

    // Quantifiers
    '*',
    '+',
    '?',
    '{',
    '}',
  };

  // Anchor regex at start of path.
  dst->assign("^");

  const char* src = str_utf8.c_str();
  int32_t length = str_utf8.length();
  int32_t position = 0;
  while (position < length) {
    UChar32 c;
    U8_NEXT(src, position, length, c);  // Macro increments |position|.
    DCHECK_GE(c, 0);
    if (c < 0)
      return false;

    // The Mac sandbox regex parser only handles printable ASCII characters.
    // 33 >= c <= 126
    if (c < 32 || c > 125) {
      return false;
    }

    for (size_t i = 0; i < arraysize(regex_special_chars); ++i) {
      if (c == regex_special_chars[i]) {
        dst->push_back('\\');
        break;
      }
    }

    dst->push_back(static_cast<char>(c));
  }

  // Make sure last element of path is interpreted as a directory. Leaving this
  // off would allow access to files if they start with the same name as the
  // directory.
  dst->append("(/|$)");

  return true;
}

// Warm up System APIs that empirically need to be accessed before the Sandbox
// is turned on.
// This method is layed out in blocks, each one containing a separate function
// that needs to be warmed up. The OS version on which we found the need to
// enable the function is also noted.
// This function is tested on the following OS versions:
//     10.5.6, 10.6.0

// static
void Sandbox::SandboxWarmup(int sandbox_type) {
  base::mac::ScopedNSAutoreleasePool scoped_pool;

  { // CGColorSpaceCreateWithName(), CGBitmapContextCreate() - 10.5.6
    base::ScopedCFTypeRef<CGColorSpaceRef> rgb_colorspace(
        CGColorSpaceCreateWithName(kCGColorSpaceGenericRGB));

    // Allocate a 1x1 image.
    char data[4];
    base::ScopedCFTypeRef<CGContextRef> context(CGBitmapContextCreate(
        data,
        1,
        1,
        8,
        1 * 4,
        rgb_colorspace,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host));

    // Load in the color profiles we'll need (as a side effect).
    ignore_result(base::mac::GetSRGBColorSpace());
    ignore_result(base::mac::GetSystemColorSpace());

    // CGColorSpaceCreateSystemDefaultCMYK - 10.6
    base::ScopedCFTypeRef<CGColorSpaceRef> cmyk_colorspace(
        CGColorSpaceCreateWithName(kCGColorSpaceGenericCMYK));
  }

  { // localtime() - 10.5.6
    time_t tv = {0};
    localtime(&tv);
  }

  { // Gestalt() tries to read /System/Library/CoreServices/SystemVersion.plist
    // on 10.5.6
    int32_t tmp;
    base::SysInfo::OperatingSystemVersionNumbers(&tmp, &tmp, &tmp);
  }

  {  // CGImageSourceGetStatus() - 10.6
     // Create a png with just enough data to get everything warmed up...
    char png_header[] = {0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A};
    NSData* data = [NSData dataWithBytes:png_header
                                  length:arraysize(png_header)];
    base::ScopedCFTypeRef<CGImageSourceRef> img(
        CGImageSourceCreateWithData((CFDataRef)data, NULL));
    CGImageSourceGetStatus(img);
  }

  {
    // Allow access to /dev/urandom.
    base::GetUrandomFD();
  }

  { // IOSurfaceLookup() - 10.7
    // Needed by zero-copy texture update framework - crbug.com/323338
    base::ScopedCFTypeRef<IOSurfaceRef> io_surface(IOSurfaceLookup(0));
  }

  // Process-type dependent warm-up.
  if (sandbox_type == 2) {
    // CFTimeZoneCopyZone() tries to read /etc and /private/etc/localtime - 10.8
    // Needed by Media Galleries API Picasa - crbug.com/151701
    CFTimeZoneCopySystem();
  }
}

// Load the appropriate template for the given sandbox type.
// Returns the template as an NSString or nil on error.
NSString* LoadSandboxTemplate(int sandbox_type) {
  return
      @"(version 1)"
      @"(define (param-defined? str) (string? (param str)))"
      @"(define disable-sandbox-denial-logging \"DISABLE_SANDBOX_DENIAL_LOGGING\")"
      @"(define enable-logging \"ENABLE_LOGGING\")"
      @"(define component-build-workaround \"COMPONENT_BUILD_WORKAROUND\")"
      @"(define permitted-dir \"PERMITTED_DIR\")"
      @"(define homedir-as-literal \"USER_HOMEDIR_AS_LITERAL\")"
      @"(define lion-or-later \"LION_OR_LATER\")"
      @"(define elcap-or-later \"ELCAP_OR_LATER\")"

      @"(deny default)"
      @"(allow signal (target self))"
      @"(allow sysctl-read)"
      @"(if (param-defined? permitted-dir)"
      @"    (begin"
      @"      (allow file-read-metadata )"
      @"      (allow file-read* file-write* (regex (param permitted-dir)))))";
}

// Turns on the OS X sandbox for this process.

// static
bool Sandbox::EnableSandbox(int sandbox_type,
                            const base::FilePath& allowed_dir) {
  DCHECK_EQ(2, sandbox_type);

  NSString* sandbox_data = LoadSandboxTemplate(sandbox_type);
  if (!sandbox_data) {
    return false;
  }

  SandboxCompiler compiler([sandbox_data UTF8String]);

  if (!allowed_dir.empty()) {
    // Add the sandbox parameters necessary to access the given directory.
    base::FilePath allowed_dir_canonical = GetCanonicalSandboxPath(allowed_dir);
    std::string regex;
    if (!QuoteStringForRegex(allowed_dir_canonical.value(), &regex)) {
      FatalStringQuoteException(allowed_dir_canonical.value());
      return false;
    }
    if (!compiler.InsertStringParam("PERMITTED_DIR", regex))
      return false;
  }

  // Enable verbose logging if enabled on the command line. (See common.sb
  // for details).
  const base::CommandLine* command_line =
      base::CommandLine::ForCurrentProcess();
  bool enable_logging =
      command_line->HasSwitch("enable-sandbox-logging");;
  if (!compiler.InsertBooleanParam("ENABLE_LOGGING", enable_logging))
    return false;

  // Without this, the sandbox will print a message to the system log every
  // time it denies a request.  This floods the console with useless spew.
  if (!compiler.InsertBooleanParam("DISABLE_SANDBOX_DENIAL_LOGGING",
                                   !enable_logging))
    return false;

  // Splice the path of the user's home directory into the sandbox profile
  // (see renderer.sb for details).
  std::string home_dir = [NSHomeDirectory() fileSystemRepresentation];

  base::FilePath home_dir_canonical =
      GetCanonicalSandboxPath(base::FilePath(home_dir));

  std::string quoted_home_dir;
  if (!QuotePlainString(home_dir_canonical.value(), &quoted_home_dir)) {
    FatalStringQuoteException(home_dir_canonical.value());
    return false;
  }

  if (!compiler.InsertStringParam("USER_HOMEDIR_AS_LITERAL", quoted_home_dir))
    return false;

  bool lion_or_later = base::mac::IsOSLionOrLater();
  if (!compiler.InsertBooleanParam("LION_OR_LATER", lion_or_later))
    return false;
  bool elcap_or_later = base::mac::IsOSElCapitanOrLater();
  if (!compiler.InsertBooleanParam("ELCAP_OR_LATER", elcap_or_later))
    return false;

#if defined(COMPONENT_BUILD)
  // dlopen() fails without file-read-metadata access if the executable image
  // contains LC_RPATH load commands. The components build uses those.
  // See http://crbug.com/127465
  if (base::mac::IsOSSnowLeopard()) {
    if (!compiler.InsertBooleanParam("COMPONENT_BUILD_WORKAROUND", true))
      return false;
  }
#endif

  // Initialize sandbox.
  std::string error_str;
  bool success = compiler.CompileAndApplyProfile(&error_str);
  DLOG_IF(FATAL, !success) << "Failed to initialize sandbox: " << error_str;
  gSandboxIsActive = success;
  return success;
}

// static
bool Sandbox::SandboxIsCurrentlyActive() {
  return gSandboxIsActive;
}

// static
base::FilePath Sandbox::GetCanonicalSandboxPath(const base::FilePath& path) {
  base::ScopedFD fd(HANDLE_EINTR(open(path.value().c_str(), O_RDONLY)));
  if (!fd.is_valid()) {
    DPLOG(FATAL) << "GetCanonicalSandboxPath() failed for: "
                 << path.value();
    return path;
  }

  base::FilePath::CharType canonical_path[MAXPATHLEN];
  if (HANDLE_EINTR(fcntl(fd.get(), F_GETPATH, canonical_path)) != 0) {
    DPLOG(FATAL) << "GetCanonicalSandboxPath() failed for: "
                 << path.value();
    return path;
  }

  return base::FilePath(canonical_path);
}
