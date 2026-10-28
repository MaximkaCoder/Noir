#ifndef RUNNER_TASKBAR_BUTTONS_H_
#define RUNNER_TASKBAR_BUTTONS_H_

#include <windows.h>
#include <shobjidl.h>
#include <wrl/client.h>

// Previous / play-pause / next under NOIR's taskbar thumbnail (the preview
// that appears when hovering the taskbar icon). They follow the playback
// state SMTC gets and report presses with the same names SMTC uses.
class TaskbarButtons {
 public:
  explicit TaskbarButtons(HWND window);
  ~TaskbarButtons();

  TaskbarButtons(const TaskbarButtons&) = delete;
  TaskbarButtons& operator=(const TaskbarButtons&) = delete;

  // Shows the buttons for the given state, or hides them when nothing is
  // loaded. Before the taskbar is ready the state is kept and applied then.
  void Update(bool visible, bool playing, bool can_previous, bool can_next);

  // Handles the taskbar's (re)creation, DPI changes and button clicks.
  // Returns true when |message| was one of them; a click sets |pressed| to
  // "play", "pause", "next" or "previous".
  bool HandleWindowMessage(UINT message, WPARAM wparam, const char** pressed);

 private:
  void Apply();
  void DestroyIcons();

  HWND window_;
  UINT created_message_;
  Microsoft::WRL::ComPtr<ITaskbarList3> taskbar_;
  bool added_ = false;

  bool visible_ = false;
  bool playing_ = false;
  bool can_previous_ = false;
  bool can_next_ = false;

  // Previous, play, pause, next; drawn for |icon_dpi_|.
  HICON icons_[4] = {};
  UINT icon_dpi_ = 0;
};

#endif  // RUNNER_TASKBAR_BUTTONS_H_
