#ifndef RUNNER_SMTC_BRIDGE_H_
#define RUNNER_SMTC_BRIDGE_H_

#include <windows.h>

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>

// Bridges Windows' System Media Transport Controls (the media flyout and the
// keyboard media keys, which work while NOIR is unfocused or minimized) to
// Dart over the "noir/smtc" method channel.
//
// Dart -> native: "metadata", "playback", "timeline", "clear".
// Native -> Dart: "button" with "play" | "pause" | "next" | "previous" |
// "stop".
//
// Nothing touches SMTC until Dart sends its first call, and every failure is
// reported back to Dart as a channel error instead of crashing the runner.
class SmtcBridge {
 public:
  SmtcBridge(flutter::BinaryMessenger* messenger, HWND window);
  ~SmtcBridge();

  SmtcBridge(const SmtcBridge&) = delete;
  SmtcBridge& operator=(const SmtcBridge&) = delete;

  // SMTC raises events on worker threads, but the Flutter channel may only be
  // used on the platform thread, so they are posted to the window as private
  // messages. Returns true when |message| was one of them.
  bool HandleWindowMessage(UINT message, WPARAM wparam);

 private:
  struct Impl;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  // Shared with in-flight artwork loads so a late completion never touches a
  // destroyed bridge.
  std::shared_ptr<Impl> impl_;
};

#endif  // RUNNER_SMTC_BRIDGE_H_
