#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <dwmapi.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1360, 860);
  if (!window.Create(L"NOIR", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  // Seamless frame on Windows 11: rounded corners and a border that blends
  // with NOIR's near-black background instead of the system accent line.
  // Older Windows versions ignore these attributes.
  {
    HWND hwnd = window.GetHandle();
    const DWORD kCornerPreference = 33;  // DWMWA_WINDOW_CORNER_PREFERENCE
    const DWORD kBorderColor = 34;       // DWMWA_BORDER_COLOR
    int round = 2;                       // DWMWCP_ROUND
    COLORREF border = RGB(0x24, 0x24, 0x24);
    DwmSetWindowAttribute(hwnd, kCornerPreference, &round, sizeof(round));
    DwmSetWindowAttribute(hwnd, kBorderColor, &border, sizeof(border));
  }

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
