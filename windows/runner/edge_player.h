#ifndef RUNNER_EDGE_PLAYER_H_
#define RUNNER_EDGE_PLAYER_H_

#include <windows.h>

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>
#include <string>

// The edge player: a small always-on-top window docked to the left or right
// edge of the primary monitor. Its outer side reaches past the screen edge,
// so the player seems to come out from behind it. It runs its own Flutter
// engine ("edgePlayerMain" in lib/main.dart) and only relays: the app sends
// the playback state over "noir/edge" ("update"), the edge view sends
// commands back ("command"), which are passed to the app unchanged.
//
// The window is clipped to the region the view asks for ("region"), so
// outside the drawn player clicks reach the windows underneath. While the
// player is open, the screen behind it is captured, scaled down, and sent to
// the view ("backdrop") to draw blurred glass; the window itself is excluded
// from screen capture so it never sees itself.
class EdgePlayer {
 public:
  explicit EdgePlayer(flutter::BinaryMessenger* app_messenger);
  ~EdgePlayer();

  EdgePlayer(const EdgePlayer&) = delete;
  EdgePlayer& operator=(const EdgePlayer&) = delete;

 private:
  using Channel = flutter::MethodChannel<flutter::EncodableValue>;

  static LRESULT CALLBACK WndProc(HWND window, UINT message, WPARAM wparam,
                                  LPARAM lparam);
  LRESULT HandleMessage(HWND window, UINT message, WPARAM wparam,
                        LPARAM lparam);

  void HandleAppCall(const flutter::MethodCall<flutter::EncodableValue>& call,
                     std::unique_ptr<flutter::MethodResult<
                         flutter::EncodableValue>> result);
  void HandleViewCall(const flutter::MethodCall<flutter::EncodableValue>& call,
                      std::unique_ptr<flutter::MethodResult<
                          flutter::EncodableValue>> result);

  bool Create();
  void Destroy();
  // Docks the window to |side_| of the primary monitor.
  void Place();
  void SendLayout();
  void ApplyVisibility();
  void ApplyRegion();
  void CheckFullscreen();
  void SendBackdrop();

  std::unique_ptr<Channel> app_channel_;

  HWND window_ = nullptr;
  std::unique_ptr<flutter::FlutterViewController> view_;
  std::unique_ptr<Channel> view_channel_;
  bool view_ready_ = false;

  // The latest "update" from the app, replayed when the view starts.
  std::unique_ptr<flutter::EncodableValue> state_;
  std::string side_ = "right";
  // Something is loaded to play.
  bool wanted_ = false;
  // Another app fills the screen (a game, a video, a presentation).
  bool fullscreen_ = false;
  // The capsule or the panel is out, not just the edge handle.
  bool open_ = false;

  RECT monitor_ = {};  // Physical pixels.
  POINT origin_ = {};  // Window position, physical pixels.
  double scale_ = 1;
  // Asked for by the view, logical pixels in window coordinates.
  RECT region_ = {};
};

#endif  // RUNNER_EDGE_PLAYER_H_
