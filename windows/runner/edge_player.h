#ifndef RUNNER_EDGE_PLAYER_H_
#define RUNNER_EDGE_PLAYER_H_

#include <windows.h>

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <shobjidl.h>
#include <wrl/client.h>

#include <memory>
#include <optional>
#include <string>

// The edge player: a small always-on-top window docked to an edge of a
// monitor while NOIR is in the background, on whichever virtual desktop
// is shown, over full-screen remote desktops too.
// Its outer side reaches past the screen edge, so the player seems to come
// out from behind it. It runs its own Flutter engine ("edgePlayerMain" in
// lib/main.dart).
//
// App -> native ("noir/edge"): "update" with the playback state, the side
// and where the player was last dropped; forwarded to the view.
// Native -> app: "command" (from the view, unchanged) and "moved" after a
// drag ({side, anchorX, anchorY} in physical screen pixels).
//
// View -> native ("noir/edge_view"): "ready"; "command"; "region" (the
// rectangle to clip the window to, logical pixels; empty when the player has
// slid away; "glass" while more than the line shows); "dragStart", "dragUpdate", "dragEnd" {centerX, centerY, depth}
// (the player's middle in window coordinates and how deep it is).
// Native -> view: "update", "layout" {side, overhang}, "backdrop", "tone"
// {luminance} (the screen beside the player).
//
// Outside the region clicks reach the windows underneath. While the glass
// shows, the screen behind it is captured, scaled down, and sent to the view
// to draw blurred glass; the window is excluded from screen capture so it
// never sees itself. With "capturable" in the update, it shows in screen
// capture instead and no backdrop is sent.
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
  // A new top-level window for the view, at |origin_|.
  HWND CreateHost();
  void Destroy();
  // Windows keep to the virtual desktop they were made on; when another one
  // is shown, the view moves into a new window made there.
  void FollowDesktop();
  // Where the docked window goes: the monitor nearest the anchor (the
  // primary one without it), its |side_|, centered on the anchor along that
  // edge. Updates |monitor_| and |scale_|.
  POINT Target();
  // Moves the window to |Target()|.
  void Place();
  SIZE WindowSize() const;
  void SendLayout();
  void ApplyVisibility();
  void ApplyRegion();
  // The screen area the window may show on: its monitor's work area while
  // docked, every monitor while it is dragged or snapping.
  RECT Bounds() const;
  void CheckFullscreen();
  // The glass shows and may see the screen: the backdrop is captured.
  bool WantsBackdrop() const;
  void SendBackdrop();
  // How light the screen is just inside the player, 0-1, for the view to
  // pick a line that stands out.
  void SendTone();
  void DragEnd(double center_x, double center_y, double depth);
  void StepSnap();

  std::unique_ptr<Channel> app_channel_;

  HWND window_ = nullptr;
  std::unique_ptr<flutter::FlutterViewController> view_;
  std::unique_ptr<Channel> view_channel_;
  bool view_ready_ = false;

  // The latest "update" from the app, replayed when the view starts.
  std::unique_ptr<flutter::EncodableValue> state_;
  // "left", "right", "top" or "bottom".
  std::string side_ = "right";
  // The player's middle where it was last dropped, physical screen pixels.
  std::optional<POINT> anchor_;
  // NOIR is in the background and something is loaded to play.
  bool wanted_ = false;
  // Another app fills the screen (a game, a video, a presentation); a
  // remote desktop doesn't count, being where the user works.
  bool fullscreen_ = false;
  // Shown in screenshots and screen sharing; then the screen behind it is
  // not captured, as the capture would see the player.
  bool capturable_ = false;

  RECT monitor_ = {};  // Work area, physical pixels.
  POINT origin_ = {};  // Window position, physical pixels.
  double scale_ = 1;
  // Asked for by the view, logical pixels in window coordinates.
  RECT region_ = {};
  // More than the line shows (the strip or the wider player).
  bool glass_ = false;
  double tone_ = -1;

  bool dragging_ = false;
  POINT grab_ = {};  // Cursor offset from |origin_| while dragging.
  bool snapping_ = false;
  POINT snap_from_ = {};
  POINT snap_to_ = {};
  ULONGLONG snap_start_ = 0;

  Microsoft::WRL::ComPtr<IVirtualDesktopManager> desktops_;
};

#endif  // RUNNER_EDGE_PLAYER_H_
