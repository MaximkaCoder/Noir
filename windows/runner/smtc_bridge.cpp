#include "smtc_bridge.h"

// unknwn.h must precede the C++/WinRT headers so classic COM interfaces
// (ISystemMediaTransportControlsInterop) work with winrt::com_ptr.
#include <unknwn.h>

#include <flutter/standard_method_codec.h>
#include <systemmediatransportcontrolsinterop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.h>
#include <winrt/Windows.Storage.Streams.h>
#include <winrt/Windows.Storage.h>

#include <chrono>
#include <cstdint>
#include <mutex>
#include <string>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using winrt::Windows::Media::MediaPlaybackStatus;
using winrt::Windows::Media::MediaPlaybackType;
using winrt::Windows::Media::SystemMediaTransportControls;
using winrt::Windows::Media::SystemMediaTransportControlsButton;
using winrt::Windows::Media::SystemMediaTransportControlsButtonPressedEventArgs;
using winrt::Windows::Media::SystemMediaTransportControlsTimelineProperties;
using winrt::Windows::Storage::StorageFile;
using winrt::Windows::Storage::Streams::RandomAccessStreamReference;

constexpr UINT kButtonMessage = WM_APP + 0x51;   // WPARAM: Button
constexpr UINT kArtworkMessage = WM_APP + 0x52;  // WPARAM: generation

enum Button : WPARAM { kPlay, kPause, kNext, kPrevious, kStop };

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

int64_t GetInt(const EncodableMap& map, const char* key) {
  const EncodableValue* value = Find(map, key);
  if (!value) return 0;
  if (const auto* narrow = std::get_if<int32_t>(value)) return *narrow;
  if (const auto* wide = std::get_if<int64_t>(value)) return *wide;
  return 0;
}

MediaPlaybackStatus ParseStatus(const std::string& status) {
  if (status == "playing") return MediaPlaybackStatus::Playing;
  if (status == "paused") return MediaPlaybackStatus::Paused;
  if (status == "changing") return MediaPlaybackStatus::Changing;
  if (status == "stopped") return MediaPlaybackStatus::Stopped;
  return MediaPlaybackStatus::Closed;
}

bool IsHttp(const std::string& uri) {
  return uri.rfind("http://", 0) == 0 || uri.rfind("https://", 0) == 0;
}

}  // namespace

struct SmtcBridge::Impl {
  explicit Impl(HWND window) : window(window) {}

  HWND window;
  SystemMediaTransportControls smtc{nullptr};
  SystemMediaTransportControls::ButtonPressed_revoker button_revoker;

  // Local artwork loads asynchronously (StorageFile); only the newest
  // request may land, and it is applied on the platform thread.
  std::mutex artwork_mutex;
  WPARAM artwork_generation = 0;
  RandomAccessStreamReference loaded_artwork{nullptr};

  SystemMediaTransportControls& Controls() {
    if (smtc) return smtc;
    auto interop = winrt::get_activation_factory<
        SystemMediaTransportControls, ISystemMediaTransportControlsInterop>();
    SystemMediaTransportControls controls{nullptr};
    winrt::check_hresult(interop->GetForWindow(
        window,
        winrt::guid_of<winrt::Windows::Media::ISystemMediaTransportControls>(),
        winrt::put_abi(controls)));
    controls.IsEnabled(false);
    HWND target = window;
    button_revoker = controls.ButtonPressed(
        winrt::auto_revoke,
        [target](const SystemMediaTransportControls&,
                 const SystemMediaTransportControlsButtonPressedEventArgs&
                     args) {
          WPARAM button;
          switch (args.Button()) {
            case SystemMediaTransportControlsButton::Play:
              button = kPlay;
              break;
            case SystemMediaTransportControlsButton::Pause:
              button = kPause;
              break;
            case SystemMediaTransportControlsButton::Next:
              button = kNext;
              break;
            case SystemMediaTransportControlsButton::Previous:
              button = kPrevious;
              break;
            case SystemMediaTransportControlsButton::Stop:
              button = kStop;
              break;
            default:
              return;
          }
          ::PostMessage(target, kButtonMessage, button, 0);
        });
    smtc = controls;
    return smtc;
  }

  WPARAM NextArtworkGeneration() {
    std::lock_guard<std::mutex> lock(artwork_mutex);
    loaded_artwork = nullptr;
    return ++artwork_generation;
  }

  static void LoadLocalArtwork(const std::shared_ptr<Impl>& self,
                               const std::string& path, WPARAM generation) {
    std::weak_ptr<Impl> weak = self;
    HWND target = self->window;
    StorageFile::GetFileFromPathAsync(winrt::to_hstring(path))
        .Completed([weak, target, generation](const auto& operation, auto) {
          try {
            auto artwork = RandomAccessStreamReference::CreateFromFile(
                operation.GetResults());
            auto impl = weak.lock();
            if (!impl) return;
            {
              std::lock_guard<std::mutex> lock(impl->artwork_mutex);
              if (impl->artwork_generation != generation) return;
              impl->loaded_artwork = artwork;
            }
            ::PostMessage(target, kArtworkMessage, generation, 0);
          } catch (...) {
            // Missing or unreadable artwork: the flyout shows no image.
          }
        });
  }
};

SmtcBridge::SmtcBridge(flutter::BinaryMessenger* messenger, HWND window)
    : channel_(std::make_unique<flutter::MethodChannel<EncodableValue>>(
          messenger, "noir/smtc",
          &flutter::StandardMethodCodec::GetInstance())),
      taskbar_(window),
      impl_(std::make_shared<Impl>(window)) {
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleMethodCall(call, std::move(result));
  });
}

SmtcBridge::~SmtcBridge() {
  channel_->SetMethodCallHandler(nullptr);
  try {
    if (impl_->smtc) {
      impl_->button_revoker.revoke();
      impl_->smtc.IsEnabled(false);
    }
  } catch (...) {
  }
  impl_->NextArtworkGeneration();
}

bool SmtcBridge::HandleWindowMessage(UINT message, WPARAM wparam) {
  const char* pressed = nullptr;
  if (taskbar_.HandleWindowMessage(message, wparam, &pressed)) {
    if (pressed) {
      channel_->InvokeMethod("button",
                             std::make_unique<EncodableValue>(pressed));
    }
    return true;
  }
  if (message == kButtonMessage) {
    const char* name = nullptr;
    switch (wparam) {
      case kPlay:
        name = "play";
        break;
      case kPause:
        name = "pause";
        break;
      case kNext:
        name = "next";
        break;
      case kPrevious:
        name = "previous";
        break;
      case kStop:
        name = "stop";
        break;
    }
    if (name) {
      channel_->InvokeMethod("button",
                             std::make_unique<EncodableValue>(name));
    }
    return true;
  }
  if (message == kArtworkMessage) {
    try {
      RandomAccessStreamReference artwork{nullptr};
      {
        std::lock_guard<std::mutex> lock(impl_->artwork_mutex);
        if (impl_->artwork_generation != wparam) return true;
        artwork = impl_->loaded_artwork;
      }
      if (artwork && impl_->smtc) {
        auto updater = impl_->smtc.DisplayUpdater();
        updater.Thumbnail(artwork);
        updater.Update();
      }
    } catch (...) {
    }
    return true;
  }
  return false;
}

void SmtcBridge::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  static const EncodableMap kEmpty;
  const auto* map = call.arguments()
                        ? std::get_if<EncodableMap>(call.arguments())
                        : nullptr;
  const EncodableMap& args = map ? *map : kEmpty;
  const std::string& method = call.method_name();

  try {
    if (method == "metadata") {
      auto& smtc = impl_->Controls();
      auto updater = smtc.DisplayUpdater();
      updater.Type(MediaPlaybackType::Music);
      auto music = updater.MusicProperties();
      music.Title(winrt::to_hstring(GetString(args, "title")));
      music.Artist(winrt::to_hstring(GetString(args, "artist")));
      music.AlbumTitle(winrt::to_hstring(GetString(args, "album")));

      const WPARAM generation = impl_->NextArtworkGeneration();
      const std::string artwork = GetString(args, "artwork");
      if (IsHttp(artwork)) {
        updater.Thumbnail(RandomAccessStreamReference::CreateFromUri(
            winrt::Windows::Foundation::Uri(winrt::to_hstring(artwork))));
      } else {
        updater.Thumbnail(nullptr);
        if (!artwork.empty()) {
          Impl::LoadLocalArtwork(impl_, artwork, generation);
        }
      }
      updater.Update();
    } else if (method == "playback") {
      // Before SMTC, which may throw.
      taskbar_.Update(true, GetString(args, "status") == "playing",
                      GetBool(args, "canPrevious"), GetBool(args, "canNext"));
      auto& smtc = impl_->Controls();
      smtc.IsPlayEnabled(GetBool(args, "canPlay"));
      smtc.IsPauseEnabled(GetBool(args, "canPause"));
      smtc.IsNextEnabled(GetBool(args, "canNext"));
      smtc.IsPreviousEnabled(GetBool(args, "canPrevious"));
      smtc.IsStopEnabled(GetBool(args, "canStop"));
      smtc.PlaybackStatus(ParseStatus(GetString(args, "status")));
      smtc.IsEnabled(true);
    } else if (method == "timeline") {
      auto& smtc = impl_->Controls();
      const std::chrono::milliseconds position(GetInt(args, "positionMs"));
      const std::chrono::milliseconds duration(GetInt(args, "durationMs"));
      SystemMediaTransportControlsTimelineProperties timeline;
      timeline.StartTime(winrt::Windows::Foundation::TimeSpan::zero());
      timeline.MinSeekTime(winrt::Windows::Foundation::TimeSpan::zero());
      timeline.EndTime(duration);
      timeline.MaxSeekTime(duration);
      timeline.Position(position);
      smtc.UpdateTimelineProperties(timeline);
    } else if (method == "clear") {
      taskbar_.Update(false, false, false, false);
      impl_->NextArtworkGeneration();
      if (impl_->smtc) {
        impl_->smtc.DisplayUpdater().ClearAll();
        impl_->smtc.DisplayUpdater().Update();
        impl_->smtc.PlaybackStatus(MediaPlaybackStatus::Closed);
        impl_->smtc.IsEnabled(false);
      }
    } else {
      result->NotImplemented();
      return;
    }
    result->Success();
  } catch (const winrt::hresult_error& e) {
    result->Error("smtc", winrt::to_string(e.message()));
  } catch (...) {
    result->Error("smtc", "Unexpected SMTC failure");
  }
}
