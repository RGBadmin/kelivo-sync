import 'sync_state_store.dart';

/// Receives a callback after a repository transaction that marked local
/// data dirty has committed. The sync service uses it to schedule the
/// debounced push; `quiet` changes (streaming checkpoints) are recorded in
/// the dirty queue but must not wake the push loop.
abstract interface class SyncWriteObserver {
  void onLocalChange({required SyncScope scope, required bool quiet});
}

/// Explicit chat-flow push triggers. The sync scheduler installs these; the
/// repository fires them after the corresponding transaction committed.
/// Pushes happen ONLY on these signals plus a fixed interval — never from
/// generic write observation.
abstract final class SyncPushSignals {
  /// The user sent a message.
  static void Function()? onUserMessageSent;

  /// An AI generation reached a terminal state (its content is final).
  static void Function()? onGenerationFinished;
}
