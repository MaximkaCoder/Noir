#include "taskbar_buttons.h"

#include <cstdint>
#include <cwchar>

namespace {

enum ButtonId : UINT { kPrevious = 1, kPlayPause, kNext };

// Segoe Fluent Icons (Windows 11) and Segoe MDL2 Assets (Windows 10) share
// these code points.
constexpr wchar_t kPreviousGlyph = 0xE892;
constexpr wchar_t kPlayGlyph = 0xE768;
constexpr wchar_t kPauseGlyph = 0xE769;
constexpr wchar_t kNextGlyph = 0xE893;

HFONT IconFont(HDC dc, int size) {
  static const wchar_t* const kFaces[] = {L"Segoe Fluent Icons",
                                          L"Segoe MDL2 Assets"};
  for (const wchar_t* face : kFaces) {
    HFONT font = ::CreateFontW(-size, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
                               DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                               CLIP_DEFAULT_PRECIS, ANTIALIASED_QUALITY,
                               DEFAULT_PITCH, face);
    HGDIOBJ old = ::SelectObject(dc, font);
    wchar_t actual[LF_FACESIZE] = {};
    ::GetTextFaceW(dc, LF_FACESIZE, actual);
    ::SelectObject(dc, old);
    if (std::wcscmp(actual, face) == 0) return font;
    ::DeleteObject(font);
  }
  return nullptr;
}

// A white |glyph| on a transparent |size| x |size| icon.
HICON GlyphIcon(wchar_t glyph, int size) {
  BITMAPINFO info = {};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = size;
  info.bmiHeader.biHeight = -size;  // Top-down.
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;

  HDC dc = ::CreateCompatibleDC(nullptr);
  void* bits = nullptr;
  HBITMAP color =
      ::CreateDIBSection(dc, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
  HFONT font = color ? IconFont(dc, size) : nullptr;
  HICON icon = nullptr;
  if (font) {
    HGDIOBJ old_bitmap = ::SelectObject(dc, color);
    HGDIOBJ old_font = ::SelectObject(dc, font);
    ::SetBkMode(dc, TRANSPARENT);
    ::SetTextColor(dc, RGB(255, 255, 255));
    RECT rect = {0, 0, size, size};
    ::DrawTextW(dc, &glyph, 1, &rect,
                DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
    ::GdiFlush();
    // GDI drew grey coverage on black; turn it into premultiplied alpha.
    auto* pixels = static_cast<uint32_t*>(bits);
    for (int i = 0; i < size * size; ++i) {
      const uint32_t a = pixels[i] & 0xFF;
      pixels[i] = (a << 24) | (a << 16) | (a << 8) | a;
    }
    ::SelectObject(dc, old_font);
    ::SelectObject(dc, old_bitmap);

    HBITMAP mask = ::CreateBitmap(size, size, 1, 1, nullptr);
    ICONINFO icon_info = {TRUE, 0, 0, mask, color};
    icon = ::CreateIconIndirect(&icon_info);
    ::DeleteObject(mask);
    ::DeleteObject(font);
  }
  if (color) ::DeleteObject(color);
  ::DeleteDC(dc);
  return icon;
}

}  // namespace

TaskbarButtons::TaskbarButtons(HWND window)
    : window_(window),
      created_message_(::RegisterWindowMessageW(L"TaskbarButtonCreated")) {}

TaskbarButtons::~TaskbarButtons() { DestroyIcons(); }

void TaskbarButtons::Update(bool visible, bool playing, bool can_previous,
                            bool can_next) {
  if (visible == visible_ && playing == playing_ &&
      can_previous == can_previous_ && can_next == can_next_) {
    return;
  }
  visible_ = visible;
  playing_ = playing;
  can_previous_ = can_previous;
  can_next_ = can_next;
  Apply();
}

bool TaskbarButtons::HandleWindowMessage(UINT message, WPARAM wparam,
                                         const char** pressed) {
  *pressed = nullptr;
  if (message == created_message_) {
    // First shown, or Explorer restarted: the buttons have to be added anew.
    taskbar_ = nullptr;
    added_ = false;
    if (SUCCEEDED(::CoCreateInstance(CLSID_TaskbarList, nullptr,
                                     CLSCTX_INPROC_SERVER,
                                     IID_PPV_ARGS(&taskbar_))) &&
        FAILED(taskbar_->HrInit())) {
      taskbar_ = nullptr;
    }
    Apply();
    return true;
  }
  if (message == WM_DPICHANGED) {
    Apply();
    return false;  // The window still has to resize itself.
  }
  if (message == WM_COMMAND && HIWORD(wparam) == THBN_CLICKED) {
    switch (LOWORD(wparam)) {
      case kPrevious:
        *pressed = "previous";
        break;
      case kPlayPause:
        *pressed = playing_ ? "pause" : "play";
        break;
      case kNext:
        *pressed = "next";
        break;
      default:
        return false;
    }
    return true;
  }
  return false;
}

void TaskbarButtons::Apply() {
  if (!taskbar_) return;
  // Before anything plays there is nothing to add; hidden buttons are only
  // needed once they exist.
  if (!added_ && !visible_) return;

  const UINT dpi = ::GetDpiForWindow(window_);
  if (dpi != icon_dpi_) {
    DestroyIcons();
    const int size = ::GetSystemMetricsForDpi(SM_CXSMICON, dpi);
    const wchar_t glyphs[4] = {kPreviousGlyph, kPlayGlyph, kPauseGlyph,
                               kNextGlyph};
    for (int i = 0; i < 4; ++i) icons_[i] = GlyphIcon(glyphs[i], size);
    icon_dpi_ = dpi;
  }

  const DWORD hidden = visible_ ? 0 : THBF_HIDDEN;
  THUMBBUTTON buttons[3] = {};
  const struct {
    UINT id;
    HICON icon;
    const wchar_t* tip;
    bool enabled;
  } specs[3] = {
      {kPrevious, icons_[0], L"Previous", can_previous_},
      {kPlayPause, playing_ ? icons_[2] : icons_[1],
       playing_ ? L"Pause" : L"Play", true},
      {kNext, icons_[3], L"Next", can_next_},
  };
  for (int i = 0; i < 3; ++i) {
    buttons[i].dwMask = THB_ICON | THB_TOOLTIP | THB_FLAGS;
    buttons[i].iId = specs[i].id;
    buttons[i].hIcon = specs[i].icon;
    wcscpy_s(buttons[i].szTip, specs[i].tip);
    buttons[i].dwFlags = static_cast<THUMBBUTTONFLAGS>(
        hidden | (specs[i].enabled ? THBF_ENABLED : THBF_DISABLED));
  }
  if (added_) {
    taskbar_->ThumbBarUpdateButtons(window_, 3, buttons);
  } else {
    added_ = SUCCEEDED(taskbar_->ThumbBarAddButtons(window_, 3, buttons));
  }
}

void TaskbarButtons::DestroyIcons() {
  for (HICON& icon : icons_) {
    if (icon) ::DestroyIcon(icon);
    icon = nullptr;
  }
  icon_dpi_ = 0;
}
