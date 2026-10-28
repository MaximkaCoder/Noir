#include "edge_player.h"

#include <dwmapi.h>
#include <flutter/standard_method_codec.h>
#include <shellapi.h>
#include <shellscalingapi.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cwchar>
#include <iterator>
#include <utility>
#include <vector>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

constexpr wchar_t kWindowClass[] = L"NOIR_EDGE_PLAYER";

// The window's size (square, for every edge) and how far it reaches past the
// screen edge, in logical pixels. The view lays the player out inside it.
constexpr double kSize = 380;
constexpr double kOverhang = 48;

// The backdrop is captured at a quarter of the logical size: it is blurred
// anyway.
constexpr double kBackdropScale = 0.25;

constexpr UINT_PTR kFullscreenTimer = 1;
constexpr UINT kFullscreenInterval = 1000;
constexpr UINT_PTR kBackdropTimer = 2;
constexpr UINT kBackdropInterval = 200;
constexpr UINT_PTR kSnapTimer = 3;
constexpr UINT kSnapInterval = 10;
constexpr ULONGLONG kSnapDuration = 420;
constexpr UINT_PTR kDesktopTimer = 4;
constexpr UINT kDesktopInterval = 250;
constexpr UINT_PTR kToneTimer = 5;
constexpr UINT kToneInterval = 400;
// How much of the screen beside the player is measured, logical pixels.
constexpr double kToneReach = 24;

bool IsSide(const std::string& side) {
  return side == "left" || side == "right" || side == "top" ||
         side == "bottom";
}

bool IsVertical(const std::string& side) {
  return side == "left" || side == "right";
}

// Remote Desktop Connection and the Windows App (Remote Desktop) client.
bool IsRemoteDesktop(HWND window) {
  if (!window) return false;
  wchar_t name[64] = {};
  ::GetClassNameW(window, name, 64);
  if (std::wcscmp(name, L"TscShellContainerClass") == 0) return true;
  DWORD process_id = 0;
  ::GetWindowThreadProcessId(window, &process_id);
  HANDLE process =
      ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, process_id);
  if (!process) return false;
  wchar_t path[MAX_PATH] = {};
  DWORD size = MAX_PATH;
  const bool named = ::QueryFullProcessImageNameW(process, 0, path, &size);
  ::CloseHandle(process);
  if (!named) return false;
  const wchar_t* file = std::wcsrchr(path, L'\\');
  file = file ? file + 1 : path;
  return _wcsicmp(file, L"mstsc.exe") == 0 || _wcsicmp(file, L"msrdc.exe") == 0;
}

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

std::optional<double> GetNumber(const EncodableMap& map, const char* key) {
  const EncodableValue* value = Find(map, key);
  if (!value) return std::nullopt;
  if (const auto* d = std::get_if<double>(value)) return *d;
  if (const auto* narrow = std::get_if<int32_t>(value)) return *narrow;
  if (const auto* wide = std::get_if<int64_t>(value)) {
    return static_cast<double>(*wide);
  }
  return std::nullopt;
}

double GetDouble(const EncodableMap& map, const char* key) {
  return GetNumber(map, key).value_or(0);
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
  if (!IsSide(side)) {
    Destroy();
    state_ = nullptr;
    result->Success();
    return;
  }
  wanted_ = GetBool(*args, "visible");
  state_ = std::make_unique<EncodableValue>(*args);
  const bool capturable = GetBool(*args, "capturable");
  if (capturable != capturable_) {
    capturable_ = capturable;
    if (window_) {
      ::SetWindowDisplayAffinity(
          window_, capturable_ ? WDA_NONE : WDA_EXCLUDEFROMCAPTURE);
      if (capturable_) {
        ::KillTimer(window_, kBackdropTimer);
      } else if (!::IsRectEmpty(&region_)) {
        SendBackdrop();
        ::SetTimer(window_, kBackdropTimer, kBackdropInterval, nullptr);
      }
    }
  }

  std::optional<POINT> anchor;
  const auto x = GetNumber(*args, "anchorX");
  const auto y = GetNumber(*args, "anchorY");
  if (x && y) {
    anchor = POINT{static_cast<LONG>(*x), static_cast<LONG>(*y)};
  }
  const bool moved =
      side != side_ || anchor.has_value() != anchor_.has_value() ||
      (anchor && (anchor->x != anchor_->x || anchor->y != anchor_->y));
  side_ = side;
  anchor_ = anchor;
  if (moved && window_ && !dragging_ && !snapping_) {
    Place();
    SendLayout();
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
    const bool was_empty = ::IsRectEmpty(&region_);
    region_ = {static_cast<LONG>(std::floor(GetDouble(*args, "left"))),
               static_cast<LONG>(std::floor(GetDouble(*args, "top"))),
               static_cast<LONG>(std::ceil(GetDouble(*args, "right"))),
               static_cast<LONG>(std::ceil(GetDouble(*args, "bottom")))};
    const bool empty = ::IsRectEmpty(&region_);
    ApplyRegion();
    ApplyVisibility();
    if (was_empty && !empty && !capturable_) {
      SendBackdrop();
      ::SetTimer(window_, kBackdropTimer, kBackdropInterval, nullptr);
    } else if (!was_empty && empty) {
      ::KillTimer(window_, kBackdropTimer);
    }
  } else if (method == "dragStart") {
    POINT cursor;
    ::GetCursorPos(&cursor);
    ::KillTimer(window_, kSnapTimer);
    snapping_ = false;
    dragging_ = true;
    grab_ = {cursor.x - origin_.x, cursor.y - origin_.y};
    ApplyRegion();
  } else if (method == "dragUpdate") {
    if (dragging_) {
      POINT cursor;
      ::GetCursorPos(&cursor);
      origin_ = {cursor.x - grab_.x, cursor.y - grab_.y};
      ::SetWindowPos(window_, nullptr, origin_.x, origin_.y, 0, 0,
                     SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    }
  } else if (method == "dragEnd" && args) {
    if (dragging_) {
      DragEnd(GetDouble(*args, "centerX"), GetDouble(*args, "centerY"),
              GetDouble(*args, "depth"));
    }
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

  origin_ = Target();
  const SIZE size = WindowSize();
  window_ = CreateHost();
  if (!window_) return false;
  if (FAILED(::CoCreateInstance(CLSID_VirtualDesktopManager, nullptr,
                                CLSCTX_ALL, IID_PPV_ARGS(&desktops_)))) {
    desktops_ = nullptr;
  }

  flutter::DartProject project(L"data");
  project.set_dart_entrypoint("edgePlayerMain");
  view_ = std::make_unique<flutter::FlutterViewController>(size.cx, size.cy,
                                                           project);
  if (!view_->engine() || !view_->view()) {
    Destroy();
    return false;
  }
  HWND content = view_->view()->GetNativeWindow();
  ::SetParent(content, window_);
  ::MoveWindow(content, 0, 0, size.cx, size.cy, TRUE);

  view_channel_ = std::make_unique<Channel>(
      view_->engine()->messenger(), "noir/edge_view",
      &flutter::StandardMethodCodec::GetInstance());
  view_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleViewCall(call, std::move(result));
  });

  ApplyRegion();
  CheckFullscreen();
  ::SetTimer(window_, kFullscreenTimer, kFullscreenInterval, nullptr);
  ::SetTimer(window_, kDesktopTimer, kDesktopInterval, nullptr);
  ::SetTimer(window_, kToneTimer, kToneInterval, nullptr);
  return true;
}

HWND EdgePlayer::CreateHost() {
  const SIZE size = WindowSize();
  HWND window = ::CreateWindowExW(
      WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE, kWindowClass,
      L"NOIR", WS_POPUP, origin_.x, origin_.y, size.cx, size.cy, nullptr,
      nullptr, ::GetModuleHandleW(nullptr), this);
  if (!window) return nullptr;
  // Lets the view's transparent pixels show what is behind the window.
  MARGINS margins = {-1};
  ::DwmExtendFrameIntoClientArea(window, &margins);
  // The backdrop capture must not see the player itself.
  if (!capturable_) {
    ::SetWindowDisplayAffinity(window, WDA_EXCLUDEFROMCAPTURE);
  }
  return window;
}

void EdgePlayer::FollowDesktop() {
  if (!desktops_ || !view_ || !::IsWindowVisible(window_)) return;
  BOOL current = TRUE;
  if (FAILED(desktops_->IsWindowOnCurrentVirtualDesktop(window_, &current)) ||
      current) {
    return;
  }
  HWND host = CreateHost();
  if (!host) return;
  HWND old = window_;
  window_ = host;
  const SIZE size = WindowSize();
  HWND content = view_->view()->GetNativeWindow();
  ::SetParent(content, window_);
  ::MoveWindow(content, 0, 0, size.cx, size.cy, TRUE);
  ApplyRegion();
  ::SetTimer(window_, kFullscreenTimer, kFullscreenInterval, nullptr);
  ::SetTimer(window_, kDesktopTimer, kDesktopInterval, nullptr);
  ::SetTimer(window_, kToneTimer, kToneInterval, nullptr);
  if (!::IsRectEmpty(&region_) && !capturable_) {
    ::SetTimer(window_, kBackdropTimer, kBackdropInterval, nullptr);
  }
  if (snapping_) ::SetTimer(window_, kSnapTimer, kSnapInterval, nullptr);
  ApplyVisibility();
  // Clear the pointer first: DestroyWindow sends messages.
  ::SetWindowLongPtrW(old, GWLP_USERDATA, 0);
  ::DestroyWindow(old);
}

void EdgePlayer::Destroy() {
  if (view_channel_) view_channel_->SetMethodCallHandler(nullptr);
  view_channel_ = nullptr;
  view_ = nullptr;
  desktops_ = nullptr;
  view_ready_ = false;
  region_ = {};
  tone_ = -1;
  dragging_ = false;
  snapping_ = false;
  if (window_) {
    // Clear the pointer first: DestroyWindow sends messages.
    ::SetWindowLongPtrW(window_, GWLP_USERDATA, 0);
    ::DestroyWindow(window_);
    window_ = nullptr;
  }
}

POINT EdgePlayer::Target() {
  HMONITOR monitor =
      anchor_ ? ::MonitorFromPoint(*anchor_, MONITOR_DEFAULTTONEAREST)
              : ::MonitorFromPoint({0, 0}, MONITOR_DEFAULTTOPRIMARY);
  MONITORINFO info = {sizeof(info)};
  ::GetMonitorInfoW(monitor, &info);
  UINT dpi_x = 96;
  UINT dpi_y = 96;
  ::GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &dpi_x, &dpi_y);
  scale_ = dpi_x / 96.0;
  // The work area, so a taskbar on that side is not covered.
  monitor_ = info.rcWork;

  const SIZE size = WindowSize();
  const LONG overhang = std::lround(kOverhang * scale_);
  if (IsVertical(side_)) {
    const LONG center =
        anchor_ ? anchor_->y : (monitor_.top + monitor_.bottom) / 2;
    const LONG top = std::clamp<LONG>(
        center - size.cy / 2, monitor_.top,
        std::max(monitor_.top, monitor_.bottom - size.cy));
    return {side_ == "left" ? monitor_.left - overhang
                            : monitor_.right - size.cx + overhang,
            top};
  }
  const LONG center =
      anchor_ ? anchor_->x : (monitor_.left + monitor_.right) / 2;
  const LONG left = std::clamp<LONG>(
      center - size.cx / 2, monitor_.left,
      std::max(monitor_.left, monitor_.right - size.cx));
  return {left, side_ == "top" ? monitor_.top - overhang
                               : monitor_.bottom - size.cy + overhang};
}

void EdgePlayer::Place() {
  origin_ = Target();
  if (!window_) return;
  const SIZE size = WindowSize();
  ::SetWindowPos(window_, HWND_TOPMOST, origin_.x, origin_.y, size.cx,
                 size.cy, SWP_NOACTIVATE);
  if (view_) {
    ::MoveWindow(view_->view()->GetNativeWindow(), 0, 0, size.cx, size.cy,
                 TRUE);
  }
  ApplyRegion();
}

SIZE EdgePlayer::WindowSize() const {
  const LONG side = std::lround(kSize * scale_);
  return {side, side};
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
  // Kept while the view slides the player away, then hidden.
  const bool shown = wanted_ || !::IsRectEmpty(&region_);
  if (shown && !fullscreen_) {
    ::SetWindowPos(window_, HWND_TOPMOST, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
  } else {
    ::ShowWindow(window_, SW_HIDE);
  }
}

RECT EdgePlayer::Bounds() const {
  if (!dragging_ && !snapping_) return monitor_;
  const int x = ::GetSystemMetrics(SM_XVIRTUALSCREEN);
  const int y = ::GetSystemMetrics(SM_YVIRTUALSCREEN);
  return {x, y, x + ::GetSystemMetrics(SM_CXVIRTUALSCREEN),
          y + ::GetSystemMetrics(SM_CYVIRTUALSCREEN)};
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
  RECT screen = Bounds();
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
  if (fullscreen && IsRemoteDesktop(::GetForegroundWindow())) {
    fullscreen = false;
  }
  if (fullscreen == fullscreen_) {
    // A full-screen remote desktop puts itself on top; stay above it.
    if (!fullscreen_ && ::IsWindowVisible(window_)) {
      ::SetWindowPos(window_, HWND_TOPMOST, 0, 0, 0, 0,
                     SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    }
    return;
  }
  fullscreen_ = fullscreen;
  ApplyVisibility();
}

void EdgePlayer::SendBackdrop() {
  if (!view_ready_ || capturable_) return;
  RECT rect = {
      origin_.x + static_cast<LONG>(std::floor(region_.left * scale_)),
      origin_.y + static_cast<LONG>(std::floor(region_.top * scale_)),
      origin_.x + static_cast<LONG>(std::ceil(region_.right * scale_)),
      origin_.y + static_cast<LONG>(std::ceil(region_.bottom * scale_)),
  };
  const RECT bounds = Bounds();
  RECT capture = {};
  if (!::IntersectRect(&capture, &rect, &bounds)) return;
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

void EdgePlayer::SendTone() {
  if (!view_ready_ || ::IsRectEmpty(&region_) || !::IsWindowVisible(window_)) {
    return;
  }
  // The strip of screen just inside the player's region, outside the
  // window's visible part, so the player itself is never measured.
  RECT rect = {
      origin_.x + static_cast<LONG>(std::floor(region_.left * scale_)),
      origin_.y + static_cast<LONG>(std::floor(region_.top * scale_)),
      origin_.x + static_cast<LONG>(std::ceil(region_.right * scale_)),
      origin_.y + static_cast<LONG>(std::ceil(region_.bottom * scale_)),
  };
  const LONG reach = std::lround(kToneReach * scale_);
  if (side_ == "right") {
    rect = {rect.left - reach, rect.top, rect.left, rect.bottom};
  } else if (side_ == "left") {
    rect = {rect.right, rect.top, rect.right + reach, rect.bottom};
  } else if (side_ == "bottom") {
    rect = {rect.left, rect.top - reach, rect.right, rect.top};
  } else {
    rect = {rect.left, rect.bottom, rect.right, rect.bottom + reach};
  }
  const RECT bounds = Bounds();
  RECT sample = {};
  if (!::IntersectRect(&sample, &rect, &bounds)) return;

  // HALFTONE averages the whole strip into the one pixel.
  BITMAPINFO info = {};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = 1;
  info.bmiHeader.biHeight = -1;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  HDC screen = ::GetDC(nullptr);
  HDC memory = ::CreateCompatibleDC(screen);
  void* bits = nullptr;
  HBITMAP bitmap =
      ::CreateDIBSection(memory, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
  double luminance = -1;
  if (bitmap) {
    HGDIOBJ old = ::SelectObject(memory, bitmap);
    ::SetStretchBltMode(memory, HALFTONE);
    ::SetBrushOrgEx(memory, 0, 0, nullptr);
    if (::StretchBlt(memory, 0, 0, 1, 1, screen, sample.left, sample.top,
                     sample.right - sample.left, sample.bottom - sample.top,
                     SRCCOPY)) {
      ::GdiFlush();
      const auto* pixel = static_cast<const uint8_t*>(bits);
      luminance =
          (0.0722 * pixel[0] + 0.7152 * pixel[1] + 0.2126 * pixel[2]) / 255;
    }
    ::SelectObject(memory, old);
    ::DeleteObject(bitmap);
  }
  ::DeleteDC(memory);
  ::ReleaseDC(nullptr, screen);
  if (luminance < 0 || std::abs(luminance - tone_) < 0.02) return;
  tone_ = luminance;
  view_channel_->InvokeMethod(
      "tone", std::make_unique<EncodableValue>(EncodableMap{
                  {EncodableValue("luminance"), EncodableValue(luminance)},
              }));
}

void EdgePlayer::DragEnd(double center_x, double center_y, double depth) {
  dragging_ = false;
  POINT cursor;
  ::GetCursorPos(&cursor);
  HMONITOR monitor = ::MonitorFromPoint(cursor, MONITOR_DEFAULTTONEAREST);
  MONITORINFO info = {sizeof(info)};
  ::GetMonitorInfoW(monitor, &info);
  const RECT& work = info.rcWork;

  // The edge nearest to where it was dropped.
  const POINT middle = {
      origin_.x + std::lround(center_x * scale_),
      origin_.y + std::lround(center_y * scale_),
  };
  const std::pair<LONG, const char*> distances[] = {
      {middle.x - work.left, "left"},
      {work.right - middle.x, "right"},
      {middle.y - work.top, "top"},
      {work.bottom - middle.y, "bottom"},
  };
  const auto nearest = std::min_element(
      std::begin(distances), std::end(distances),
      [](const auto& a, const auto& b) { return a.first < b.first; });
  const std::string side = nearest->second;

  if (side != side_) {
    // The view lays the player out against the new edge; move the window
    // so the player stays where it was dropped until it snaps.
    const double near_edge = kOverhang + depth / 2;
    const double far_edge = kSize - near_edge;
    const double mid = kSize / 2;
    const double x = side == "left"    ? near_edge
                     : side == "right" ? far_edge
                                       : mid;
    const double y = side == "top"      ? near_edge
                     : side == "bottom" ? far_edge
                                        : mid;
    origin_.x += std::lround((center_x - x) * scale_);
    origin_.y += std::lround((center_y - y) * scale_);
    ::SetWindowPos(window_, nullptr, origin_.x, origin_.y, 0, 0,
                   SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    side_ = side;
    SendLayout();
  }
  anchor_ = middle;

  snap_from_ = origin_;
  snap_to_ = Target();
  snap_start_ = ::GetTickCount64();
  snapping_ = true;
  ::SetTimer(window_, kSnapTimer, kSnapInterval, nullptr);

  app_channel_->InvokeMethod(
      "moved", std::make_unique<EncodableValue>(EncodableMap{
                   {EncodableValue("side"), EncodableValue(side_)},
                   {EncodableValue("anchorX"),
                    EncodableValue(static_cast<int32_t>(anchor_->x))},
                   {EncodableValue("anchorY"),
                    EncodableValue(static_cast<int32_t>(anchor_->y))},
               }));
}

void EdgePlayer::StepSnap() {
  const double t = std::min(
      1.0, static_cast<double>(::GetTickCount64() - snap_start_) /
               kSnapDuration);
  // Eases out with a small overshoot, so it lands against the edge a
  // little past it (clipped there) and settles back: it sticks.
  constexpr double kOvershoot = 1.3;
  const double eased = 1 + (kOvershoot + 1) * std::pow(t - 1, 3) +
                       kOvershoot * std::pow(t - 1, 2);
  origin_ = {
      snap_from_.x + static_cast<LONG>(
                         std::lround((snap_to_.x - snap_from_.x) * eased)),
      snap_from_.y + static_cast<LONG>(
                         std::lround((snap_to_.y - snap_from_.y) * eased)),
  };
  ::SetWindowPos(window_, nullptr, origin_.x, origin_.y, 0, 0,
                 SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
  if (t >= 1) {
    ::KillTimer(window_, kSnapTimer);
    snapping_ = false;
    Place();
  }
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
      if (wparam == kSnapTimer) StepSnap();
      if (wparam == kDesktopTimer) FollowDesktop();
      if (wparam == kToneTimer) SendTone();
      return 0;
    case WM_DPICHANGED:
      if (dragging_ || snapping_) {
        // Carried onto a monitor with another scale: take its size and
        // keep following the cursor.
        scale_ = LOWORD(wparam) / 96.0;
        const auto* suggested = reinterpret_cast<const RECT*>(lparam);
        const SIZE size = WindowSize();
        origin_ = {suggested->left, suggested->top};
        ::SetWindowPos(window_, nullptr, origin_.x, origin_.y, size.cx,
                       size.cy, SWP_NOZORDER | SWP_NOACTIVATE);
        if (view_) {
          ::MoveWindow(view_->view()->GetNativeWindow(), 0, 0, size.cx,
                       size.cy, TRUE);
        }
        return 0;
      }
      Place();
      return 0;
    case WM_DISPLAYCHANGE:
      if (!dragging_) Place();
      return 0;
    case WM_SETTINGCHANGE:
      if (wparam == SPI_SETWORKAREA && !dragging_) Place();
      break;
    case WM_CLOSE:
      // Closed with the app, never on its own.
      return 0;
  }
  return ::DefWindowProcW(window, message, wparam, lparam);
}
