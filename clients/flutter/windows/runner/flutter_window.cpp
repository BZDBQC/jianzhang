#include "flutter_window.h"

#include <optional>
#include <cstdio>

#include "flutter/generated_plugin_registrant.h"

namespace {
constexpr UINT kReadinessFrameMessage = WM_APP + 0x504;
}

FlutterWindow::FlutterWindow(const flutter::DartProject& project, uint64_t started_at)
    : project_(project), started_at_(started_at) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  performance_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "jianzhang/performance",
      &flutter::StandardMethodCodec::GetInstance());
  performance_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() != "reportFullyDrawn") {
          result->NotImplemented();
          return;
        }
        if (readiness_result_) {
          result->Error("READY_PENDING", "Readiness has already been requested.");
          return;
        }
        readiness_result_ = std::move(result);
        if (ready_ms_ >= 0) {
          CompleteReadiness();
        } else if (initial_frame_ready_ &&
                   !::PostMessage(GetHandle(), kReadinessFrameMessage, 0, 0)) {
          readiness_result_->Error("READY_DISPATCH_FAILED", "Could not request a readiness frame.");
          readiness_result_.reset();
        }
      });

  flutter_controller_->engine()->SetNextFrameCallback([this]() {
    initial_frame_ready_ = true;
    this->Show();
    // The wrapper clears its callback after this lambda returns. Re-arm only
    // through the queued platform message, after the initial callback finishes.
    if (readiness_result_ &&
        !::PostMessage(GetHandle(), kReadinessFrameMessage, 0, 0)) {
      readiness_result_->Error("READY_DISPATCH_FAILED", "Could not request a readiness frame.");
      readiness_result_.reset();
    }
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (readiness_result_) {
    readiness_result_->Error("ENGINE_CLOSED", "The window closed before readiness.");
    readiness_result_.reset();
  }
  if (performance_channel_) {
    performance_channel_->SetMethodCallHandler(nullptr);
    performance_channel_.reset();
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::CompleteReadiness() {
  if (!renderer_frame_ready_ || !readiness_result_) return;
  if (ready_ms_ < 0) {
    ready_ms_ = static_cast<int64_t>(::GetTickCount64() - started_at_);
    std::printf("JIANZHANG_READY {\"readyMs\":%lld,\"rendererFirstFrame\":true}\n",
                static_cast<long long>(ready_ms_));
    std::fflush(stdout);
  }
  readiness_result_->Success(flutter::EncodableValue(flutter::EncodableMap{
      {flutter::EncodableValue("readyMs"), flutter::EncodableValue(ready_ms_)},
      {flutter::EncodableValue("rendererFirstFrame"), flutter::EncodableValue(true)}}));
  readiness_result_.reset();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case kReadinessFrameMessage:
      if (flutter_controller_ && initial_frame_ready_ && readiness_result_ &&
          !readiness_frame_requested_) {
        readiness_frame_requested_ = true;
        flutter_controller_->engine()->SetNextFrameCallback([this]() {
          renderer_frame_ready_ = true;
          CompleteReadiness();
        });
        flutter_controller_->ForceRedraw();
      }
      return 0;
    case WM_FONTCHANGE:
      if (flutter_controller_) flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
