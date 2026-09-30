#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <cstdlib>
#include <string>
#include <vector>
#include "flutter_window.h"
#include "utils.h"
#include <shobjidl.h>

namespace {

constexpr wchar_t kPrimaryInstanceMutex[] =
    L"Local\\PureLive_Primary_Instance_v1";

// Native title shown by the taskbar, Alt+Tab and Task Manager (the Chinese app name);
// the in-app title bar is drawn by Flutter. Escaped to keep the source ASCII.
constexpr wchar_t kWindowTitle[] = L"\u7EAF\u7CB9\u76F4\u64AD";

void BringPrimaryWindowToFront() {
  const HWND window =
      ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", kWindowTitle);
  if (window == nullptr) {
    return;
  }
  if (::IsIconic(window)) {
    ::ShowWindowAsync(window, SW_RESTORE);
  } else {
    ::ShowWindowAsync(window, SW_SHOW);
  }
  ::SetWindowPos(window, HWND_TOP, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
  ::SetForegroundWindow(window);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  // Internal sentinel used by the in-app restart flow (see
  // FlutterWindow::LaunchSuccessorAndQuit). It is consumed here and never
  // forwarded to the Dart entrypoint.
  constexpr char kRestartAppArg[] = "--restart-app";
  bool is_restart = false;
  std::vector<std::string> entrypoint_arguments;
  for (const std::string& argument : command_line_arguments) {
    if (argument == kRestartAppArg) {
      is_restart = true;
    } else {
      entrypoint_arguments.push_back(argument);
    }
  }

  // Reject a duplicate primary process before allocating a Flutter engine,
  // GPU surface, Dart isolate or plugins. The Dart single-instance channel is
  // retained for argument forwarding; this early fence prevents the brief
  // decoder/UI stall observed when users launch the installed shortcut twice.
  HANDLE primary_instance_mutex = nullptr;
  // Business arguments (shared URLs, protocol links and --instance=...) must
  // still reach the Dart single-instance channel for forwarding or intentional
  // multi-window creation. The common duplicate-shortcut case has no arguments
  // and can be rejected here without starting a second Flutter engine.
  if (is_restart) {
    // Successor process of an in-app restart: block until the previous
    // instance exits and releases the named mutex, so exactly one engine is
    // ever alive. A successful wait (including WAIT_ABANDONED when the old
    // process was terminated) transfers mutex ownership to this thread; keep
    // the handle open for the process lifetime.
    primary_instance_mutex = ::OpenMutexW(SYNCHRONIZE, FALSE,
                                         kPrimaryInstanceMutex);
    if (primary_instance_mutex != nullptr) {
      const DWORD wait_result =
          ::WaitForSingleObject(primary_instance_mutex, 15000);
      if (wait_result != WAIT_OBJECT_0 && wait_result != WAIT_ABANDONED) {
        ::CloseHandle(primary_instance_mutex);
        primary_instance_mutex =
            ::CreateMutexW(nullptr, TRUE, kPrimaryInstanceMutex);
      }
    } else {
      primary_instance_mutex =
          ::CreateMutexW(nullptr, TRUE, kPrimaryInstanceMutex);
    }
  } else if (entrypoint_arguments.empty()) {
    primary_instance_mutex =
        ::CreateMutexW(nullptr, TRUE, kPrimaryInstanceMutex);
    if (primary_instance_mutex != nullptr &&
        ::GetLastError() == ERROR_ALREADY_EXISTS) {
      BringPrimaryWindowToFront();
      ::CloseHandle(primary_instance_mutex);
      return EXIT_SUCCESS;
    }
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  {
    flutter::DartProject project(L"data");

    project.set_dart_entrypoint_arguments(std::move(entrypoint_arguments));
    SetCurrentProcessExplicitAppUserModelID(L"com.mystyle.purelive");
    FlutterWindow window(project);
    Win32Window::Point origin(10, 10);
    Win32Window::Size size(1280, 720);
    if (!window.Create(kWindowTitle, origin, size)) {
      return EXIT_FAILURE;
    }
    window.SetQuitOnClose(true);

    ::MSG msg;
    while (::GetMessage(&msg, nullptr, 0, 0)) {
      ::TranslateMessage(&msg);
      ::DispatchMessage(&msg);
    }
  }

  ::CoUninitialize();
  // Flutter and plugin objects are already destroyed above. Bypass process
  // detach hooks in optional DLLs that can otherwise keep the process alive.
  ::TerminateProcess(::GetCurrentProcess(), EXIT_SUCCESS);
  return EXIT_SUCCESS;
}
