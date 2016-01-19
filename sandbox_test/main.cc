#include <iostream>
#include <string>
#include <vector>

#include "base/command_line.h"
#include "base/files/file_path.h"
#include "base/files/file_util.h"
#include "base/process/launch.h"
#include "base/process/process.h"
#include "base/strings/string_split.h"
#include "sandbox_test/sandbox_init_mac.h"
#include "sandbox_test/sandbox_mac.h"

const char kWriteFilenameSwitch[] = "write-file";
const char kProcessTypeSwitch[] = "process-type";
const char kAllowedDirSwitch[] = "allowed-dir";

const char kAllowedDirName[] = "allowed";

int SetupSimpleSandbox() {
  base::FilePath allowed_dir =
      base::MakeAbsoluteFilePath(base::FilePath(kAllowedDirName));
  std::string final_allowed_dir;
  if (!Sandbox::QuoteStringForRegex(allowed_dir.value(), &final_allowed_dir))
    return 3;

  // Build up a sandbox profile that only allows access to a single directory.
  std::string sandbox_profile =
      "(version 1)"
      "(define perm_dir (param \"PERMITTED_DIR\"))"
      "(deny default)"
      "(allow signal (target self))"
      "(allow sysctl-read)"
      "(if (string? perm_dir)"
      "    (begin"
      "       (allow file-read-metadata )"
      "       (allow file-read* file-write* (regex (string-append #\"\" "
      "perm_dir)))))";

  // Setup the parameters to pass to the sandbox.
  SandboxCompiler compiler(sandbox_profile);
  if (!compiler.InsertStringParam("PERMITTED_DIR", final_allowed_dir))
    return 4;

  // Enable Sandbox.
  std::string error_str;
  if (!compiler.CompileAndApplyProfile(&error_str)) {
    return 5;
  }

  return 0;
}

int DoChild() {
  base::FilePath filename =
      base::CommandLine::ForCurrentProcess()->GetSwitchValuePath(
          kWriteFilenameSwitch);
  if (filename.empty())
    return 1;

#if 0  // A simplest sandbox.
  int res = SetupSimpleSandbox();
  if (res != 0)
    return res;
#endif

  std::string text_to_write = "Hello, world!";
  if (base::WriteFile(filename, text_to_write.data(), text_to_write.size()) < 0)
    return 2;

  return 0;
}

void RunChild(const std::string& filename) {
  base::CommandLine cmd_line = *base::CommandLine::ForCurrentProcess();
  cmd_line.SetProgram(base::MakeAbsoluteFilePath(cmd_line.GetProgram()));
  cmd_line.AppendSwitchPath(kWriteFilenameSwitch, base::FilePath(filename));

  cmd_line.AppendSwitchPath(kAllowedDirSwitch, base::FilePath(kAllowedDirName));
  cmd_line.AppendSwitchASCII(kProcessTypeSwitch, "child");

  base::Process child_process = base::LaunchProcess(cmd_line,
                                                    base::LaunchOptions());
  if (!child_process.IsValid()) {
    std::cout << "Cannot spawn the process\n";
    return;
  }
  int code = -1;
  if (!child_process.WaitForExit(&code)) {
    std::cout << "Cannot wait for the process\n";
    return;
  }

  std::cout << "Process exited with code " << code << "\n";
}

void CatFile(const std::string& filename) {
  std::string contents;
  if (!base::ReadFileToString(base::FilePath(filename), &contents)) {
    std::cout << "Cannot read '" << filename << "'\n";
    return;
  }
  std::cout << contents << "\n";
}

int main(int argc, char **argv) {
  CHECK(base::CommandLine::Init(argc, argv));
  CHECK(InitializeSandbox());

  if (!base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII(
          kProcessTypeSwitch).empty())
    return DoChild();

  std::cout << "Sandbox testing utility\n";

  std::string cmd;
  for (std::cout << "> "; std::getline(std::cin, cmd); std::cout << "> ") {
    std::vector<std::string> splitted = base::SplitString(
        cmd, " ", base::TRIM_WHITESPACE, base::SPLIT_WANT_NONEMPTY);
    if (splitted.empty())
      continue;
    cmd = splitted.front();

    if (cmd == "quit" or cmd == "exit")
      break;

    if (cmd == "help") {
      std::cout << "Available commands:\n";
      std::cout << "  help\n";
      std::cout << "  quit\n";
      std::cout << "  write <file_name>\n";
      std::cout << "  cat <file_name>\n";
      continue;
    }

    if (cmd == "write") {
      if (splitted.size() != 2) {
        std::cout << "'write' should have one parameter - filename";
        continue;
      }

      RunChild(splitted[1]);
      continue;
    }

    if (cmd == "cat") {
      if (splitted.size() != 2) {
        std::cout << "'cat' should have one parameter - filename";
        continue;
      }

      CatFile(splitted[1]);
      continue;
    }

    std::cout << "Unknown command\n";
  }

  return 0;
}
