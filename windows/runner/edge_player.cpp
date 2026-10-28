#include "edge_player.h"

#include <dwmapi.h>
#include <flutter/standard_method_codec.h>
#include <shellapi.h>
#include <shellscalingapi.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <optional>
#include <vector>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

constexpr wchar_t kWindowClass[] = L"NOIR_EDGE_PLAYER";

// The window's size and how far it reaches past the screen edge, in logical
// pixels. The view lays the player out inside this box.
constexpr double kWidth = 360;
constexpr double kHeight = 520;
constexpr double kOverhang = 48;

// The backdrop is captured at a quarter of the logical size: it is blurred
// anyway.
constexpr double kBackdropScale = 0.25;

constexpr UINT_PTR kFullscreenTimer = 1;
constexpr UINT kFullscreenInterval = 1000;
constexpr UINT_PTR kBackdropTimer = 2;
constexpr UINT kBackdropInterval = 200;

const EncodableValue* Find(const EncodableMap& map, const char* key) {
  auto it = map.find(EncodableValue(key));
  return it == map.end() ? nullptr : &it->second;
}

std::string GetString(const EncodableMap& map, const char* key) {
  const EncodableValue* value = Find(map, key);
  const auto* text = value ? std::get_if<std::string>(value) : nullptr;
  return text ? *text : std::string();
}

bool GetBool(const EncodableMap& map, const char* key) {
  const EncodableValue* value = Find(map, key);
  const auto* flag = value ? std::get_if<bool>(value) : nullptr;
  return flag && *flag;
}

double GetDouble(const EncodableMap& map, const char* key) {
  const EncodableValue* value = Find(map, key);
  if (!value) return 0;
  if (const auto* d = std::get_if<double>(value)) return *d;
  if (const auto* narrow = std::get_if<int32_t>(value)) return *narrow;
  if (const auto* wide = std::get_if<int64_t>(value)) {
    return static_cast<double>(*wide);
  }
  return 0;
}

}  // namespace

EdgePlayer::EdgePlayer(flutter::BinaryMessenger* app_messenger)
    : app_channel_(std::make_unique<Channel>(
          app_messenger, "noir/edge",
          &flutter::StandardMethodCodec::GetInstance())) {
  app_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleAppCall(call, std::move(result));
  });
}

EdgePlayer::~EdgePlayer() {
  app_channel_->SetMethodCallHandler(nullptr);
  Destroy();
}

void EdgePlayer::HandleAppCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  if (call.method_name() != "update") {
    result->NotImplemented();
    return;
  }
  const auto* args = call.arguments()
                         ? std::get_if<EncodableMap>(call.arguments())
                         : nullptr;
  if (!args) {
    result->Error("edge", "update needs a map");
    return;
  }
  const std::string side = GetString(*args, "side");
  if (side != "left" && side != "right") {
    Destroy();
    state_ = nullptr;
    result->Success();
    return;
  }
  wanted_ = GetBool(*args, "visible");
  state_ = std::make_unique<EncodableValue>(*args);
  if (side != side_) {
    side_ = side;
    if (window_) {
      Place();
      SendLayout();
    }
  }
  if (!window_ && wanted_ && !Create()) {
    result->Error("edge", "The edge player window could not be created");
    return;
  }
  if (view_ready_) {
    view_channel_->InvokeMethod("update",
                                std::make_unique<EncodableValue>(*state_));
  }
  ApplyVisibility();
  result->Success();
}

void EdgePlayer::HandleViewCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const std::string& method = call.method_name();
  const auto* args = call.arguments()
                         ? std::get_if<EncodableMap>(call.arguments())
                         : nullptr;
  if (method == "ready") {
    view_ready_ = true;
    SendLayout();
    if (state_) {
      view_channel_->InvokeMethod("update",
                                  std::make_unique<EncodableValue>(*state_));
    }
  } else if (method == "command" && args) {
    app_channel_->InvokeMethod("command",
                               std::make_unique<EncodableValue>(*args));
  } else if (method == "region" && args) {
    region_ = {static_cast<LONG>(std::floor(GetDouble(*args, "left"))),
               static_cast<LONG>(std::floor(GetDouble(*args, "top"))),
               static_cast<LONG>(std::ceil(GetDouble(*args, "right"))),
               static_cast<LONG>(std::ceil(GetDouble(*args, "bottom")))};
    const bool open = GetBool(*args, "open");
    ApplyRegion();
    if (open && !open_) {
      SendBackdrop();
      ::SetTimer(window_, kBackdropTimer, kBackdropInterval, nullptr);
    } else if (!open && open_) {
      ::KillTimer(window_, kBackdropTimer);
    }
    open_ = open;
  } else {
    result->NotImplemented();
    return;
  }
  result->Success();
}

bool EdgePlayer::Create() {
  static bool registered = false;
  if (!registered) {
    WNDCLASSEXW window_class = {sizeof(window_class)};
    window_class.lpfnWndProc = WndProc;
    window_class.hInstance = ::GetModuleHandleW(nullptr);
    window_class.hCursor = ::LoadCursorW(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClass;
    registered = ::RegisterClassExW(&window_class) != 0;
    if (!registered) return false;
  }

  Place();
  const int width = static_cast<int>(std::lround(kWidth * scale_));
  const int height = static_cast<int>(std::lround(kHeight * scale_));
  window_ = ::CreateWindowExW(
      WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE, kWindowClass,
      L"NOIR", WS_POPUP, origin_.x, origin_.y, width, height, nullptr,
      nullptr, ::GetModuleHandleW(nullptr), this);
  if (!window_) return false;

  // Lets the view's transparent pixels show what is behind the window.
  MARGINS margins = {-1};
  ::DwmExtendFrameIntoClientArea(window_, &margins);
  // The backdrop capture must not see the player itself.
  ::SetWindowDisplayAffinity(window_, WDA_EXCLUDEFROMCAPTURE);

  flutter::DartProject project(L"data");
  project.set_dart_entrypoint("edgePlayerMain");
  view_ = std::make_unique<flutter::FlutterViewController>(width, height,
                                                           project);
  if (!view_->engine() || !view_->view()) {
    Destroy();
    return false;
  }
  HWND content = view_->view()->GetNativeWindow();
  ::SetParent(content, window_);
  ::MoveWindow(content, 0, 0, width, height, TRUE);

  view_channel_ = std::make_unique<Channel>(
      view_->engine()->messenger(), "noir/edge_view",
      &flutter::StandardMethodCodec::GetInstance());
  view_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleViewCall(call, std::move(result));
  });

  ApplyRegion();
  CheckFullscreen();
  ::SetTimer(window_, kFullscreenTimer, kFullscreenInterval, nullptr);
  return true;
}

void EdgePlayer::Destroy() {
  if (view_channel_) view_channel_->SetMethodCallHandler(nullptr);
  view_channel_ = nullptr;
  view_ = nullptr;
  view_ready_ = false;
  open_ = false;
  region_ = {};
  if (window_) {
    // Clear the pointer first: DestroyWindow sends messages.
    ::SetWindowLongPtrW(window_, GWLP_USERDATA, 0);
    ::DestroyWindow(window_);
    window_ = nullptr;
  }
}

void EdgePlayer::Place() {
  HMONITOR monitor = ::MonitorFromPoint({0, 0}, MONITOR_DEFAULTTOPRIMARY);
  MONITORINFO info = {sizeof(info)};
  ::GetMonitorInfoW(monitor, &info);
  UINT dpi_x = 96;
  UINT dpi_y = 96;
  ::GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &dpi_x, &dpi_y);
  scale_ = dpi_x / 96.0;
  // The work area, so a taskbar on that side is not covered.
  monitor_ = info.rcWork;

  const int width = static_cast<int>(std::lround(kWidth * scale_));
  const int height = static_cast<int>(std::lround(kHeight * scale_));
  const int overhang = static_cast<int>(std::lround(kOverhang * scale_));
  origin_.x = side_ == "left" ? monitor_.left - overhang
                              : monitor_.right - width + overhang;
  origin_.y = monitor_.top + (monitor_.bottom - monitor_.top - height) / 2;

  if (!window_) return;
  ::SetWindowPos(window_, HWND_TOPMOST, origin_.x, origin_.y, width, height,
                 SWP_NOACTIVATE);
  if (view_) {
    ::MoveWindow(view_->view()->GetNativeWindow(), 0, 0, width, height, TRUE);
  }
  ApplyRegion();
}

void EdgePlayer::SendLayout() {
  if (!view_ready_) return;
  view_channel_->InvokeMethod(
      "layout", std::make_unique<EncodableValue>(EncodableMap{
                    {EncodableValue("side"), EncodableValue(side_)},
                    {EncodableValue("overhang"), EncodableValue(kOverhang)},
                }));
}

void EdgePlayer::ApplyVisibility() {
  if (!window_) return;
  if (wanted_ && !fullscreen_) {
    ::SetWindowPos(window_, HWND_TOPMOST, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
  } else {
    ::ShowWindow(window_, SW_HIDE);
  }
}

void EdgePlayer::ApplyRegion() {
  if (!window_) return;
  // The asked-for rectangle, in physical pixels, cut to the screen so the
  // part past the edge never shows on a neighboring monitor.
  RECT rect = {
      static_cast<LONG>(std::floor(region_.left * scale_)),
      static_cast<LONG>(std::floor(region_.top * scale_)),
      static_cast<LONG>(std::ceil(region_.right * scale_)),
      static_cast<LONG>(std::ceil(region_.bottom * scale_)),
  };
  RECT screen = monitor_;
  ::OffsetRect(&screen, -origin_.x, -origin_.y);
  RECT visible = {};
  ::IntersectRect(&visible, &rect, &screen);
  HRGN region = ::CreateRectRgn(visible.left, visible.top, visible.right,
                                visible.bottom);
  // The system owns the region from here on.
  ::SetWindowRgn(window_, region, TRUE);
}

void EdgePlayer::CheckFullscreen() {
  QUERY_USER_NOTIFICATION_STATE state;
  bool fullscreen = false;
  if (SUCCEEDED(::SHQueryUserNotificationState(&state))) {
    fullscreen = state == QUNS_BUSY || state == QUNS_RUNNING_D3D_FULL_SCREEN ||
                 state == QUNS_PRESENTATION_MODE;
  }
  if (fullscreen == fullscreen_) return;
  fullscreen_ = fullscreen;
  ApplyVisibility();
}

void EdgePlayer::SendBackdrop() {
  if (!view_ready_) return;
  RECT rect = {
      origin_.x + static_cast<LONG>(std::floor(region_.left * scale_)),
      origin_.y + static_cast<LONG>(std::floor(region_.top * scale_)),
      origin_.x + static_cast<LONG>(std::ceil(region_.right * scale_)),
      origin_.y + static_cast<LONG>(std::ceil(region_.bottom * scale_)),
  };
  RECT capture = {};
  if (!::IntersectRect(&capture, &rect, &monitor_)) return;
  const int width = capture.right - capture.left;
  const int height = capture.bottom - capture.top;
  const int pixel_width = std::max(
      1, static_cast<int>(std::ceil(width / scale_ * kBackdropScale)));
  const int pixel_height = std::max(
      1, static_cast<int>(std::ceil(height / scale_ * kBackdropScale)));

  BITMAPINFO info = {};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = pixel_width;
  info.bmiHeader.biHeight = -pixel_height;  // Top-down.
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;

  HDC screen = ::GetDC(nullptr);
  HDC memory = ::CreateCompatibleDC(screen);
  void* bits = nullptr;
  HBITMAP bitmap =
      ::CreateDIBSection(memory, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
  std::vector<uint8_t> pixels;
  if (bitmap) {
    HGDIOBJ old = ::SelectObject(memory, bitmap);
    ::SetStretchBltMode(memory, HALFTONE);
    ::SetBrushOrgEx(memory, 0, 0, nullptr);
    if (::StretchBlt(memory, 0, 0, pixel_width, pixel_height, screen,
                     capture.left, capture.top, width, height, SRCCOPY)) {
      ::GdiFlush();
      const auto* begin = static_cast<const uint8_t*>(bits);
      pixels.assign(begin, begin + pixel_width * pixel_height * 4);
      for (size_t i = 3; i < pixels.size(); i += 4) pixels[i] = 0xFF;
    }
    ::SelectObject(memory, old);
    ::DeleteObject(bitmap);
  }
  ::DeleteDC(memory);
  ::ReleaseDC(nullptr, screen);
  if (pixels.empty()) return;

  view_channel_->InvokeMethod(
      "backdrop",
      std::make_unique<EncodableValue>(EncodableMap{
          {EncodableValue("left"),
           EncodableValue((capture.left - origin_.x) / scale_)},
          {EncodableValue("top"),
           EncodableValue((capture.top - origin_.y) / scale_)},
          {EncodableValue("width"), EncodableValue(width / scale_)},
          {EncodableValue("height"), EncodableValue(height / scale_)},
          {EncodableValue("pixelWidth"), EncodableValue(pixel_width)},
          {EncodableValue("pixelHeight"), EncodableValue(pixel_height)},
          {EncodableValue("pixels"), EncodableValue(std::move(pixels))},
      }));
}

LRESULT CALLBACK EdgePlayer::WndProc(HWND window, UINT message, WPARAM wparam,
                                     LPARAM lparam) {
  if (message == WM_NCCREATE) {
    auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
    ::SetWindowLongPtrW(window, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(create->lpCreateParams));
  }
  auto* self = reinterpret_cast<EdgePlayer*>(
      ::GetWindowLongPtrW(window, GWLP_USERDATA));
  if (self) return self->HandleMessage(window, message, wparam, lparam);
  return ::DefWindowProcW(window, message, wparam, lparam);
}

LRESULT EdgePlayer::HandleMessage(HWND window, UINT message, WPARAM wparam,
                                  LPARAM lparam) {
  if (view_) {
    std::optional<LRESULT> result =
        view_->HandleTopLevelWindowProc(window, message, wparam, lparam);
    if (result) return *result;
  }
  switch (message) {
    case WM_MOUSEACTIVATE:
      // Clicking the player must not take focus from the app in front.
      return MA_NOACTIVATE;
    case WM_ERASEBKGND:
      return 1;
    case WM_TIMER:
      if (wparam == kFullscreenTimer) CheckFullscreen();
      if (wparam == kBackdropTimer) SendBackdrop();
      return 0;
    case WM_DISPLAYCHANGE:
    case WM_DPICHANGED:
      Place();
      return 0;
    case WM_SETTINGCHANGE:
      if (wparam == SPI_SETWORKAREA) Place();
      break;
    case WM_CLOSE:
      // Closed with the app, never on its own.
      return 0;
  }
  return ::DefWindowProcW(window, message, wparam, lparam);
}
