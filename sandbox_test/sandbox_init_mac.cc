// Copyright (c) 2011 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "sandbox_test/sandbox_init_mac.h"

#include "base/command_line.h"
#include "base/files/file_path.h"
#include "base/logging.h"
#include "base/memory/shared_memory.h"
#include "base/memory/shared_memory_handle.h"
#include "sandbox_test/sandbox_mac.h"

bool InitializeSandbox(int sandbox_type, const base::FilePath& allowed_dir) {
  // Warm up APIs before turning on the sandbox.
  Sandbox::SandboxWarmup(sandbox_type);

  // Actually sandbox the process.
  return Sandbox::EnableSandbox(sandbox_type, allowed_dir);
}

// Fill in |sandbox_type| and |allowed_dir| based on the command line,  returns
// false if the current process type doesn't need to be sandboxed or if the
// sandbox was disabled from the command line.
bool GetSandboxTypeFromCommandLine(int* sandbox_type,
                                   base::FilePath* allowed_dir) {
  DCHECK(sandbox_type);
  DCHECK(allowed_dir);

  *sandbox_type = -1;
  *allowed_dir = base::FilePath();  // Empty by default.

  const base::CommandLine& command_line =
      *base::CommandLine::ForCurrentProcess();
  if (command_line.HasSwitch("no-sandbox"))
    return false;

  std::string process_type =
      command_line.GetSwitchValueASCII("process-type");
  if (process_type.empty()) {
    // Main process isn't sandboxed.
    return false;
  } else {
    // Utility process sandbox.
    *sandbox_type = 2;
    *allowed_dir = command_line.GetSwitchValuePath("allowed-dir");
  }

  return true;
}

bool InitializeSandbox() {
  int sandbox_type = 0;
  base::FilePath allowed_dir;
  if (!GetSandboxTypeFromCommandLine(&sandbox_type, &allowed_dir))
    return true;
  return InitializeSandbox(sandbox_type, allowed_dir);
}

bool BrokerDuplicateSharedMemoryHandle(
    const base::SharedMemoryHandle& source_handle,
    base::ProcessId target_process_id,
    base::SharedMemoryHandle* target_handle) {
  *target_handle = base::SharedMemory::DuplicateHandle(source_handle);
  return base::SharedMemory::IsHandleValid(*target_handle);
}
