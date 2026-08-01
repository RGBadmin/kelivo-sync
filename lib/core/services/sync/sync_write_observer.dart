import 'sync_state_store.dart';

/// Receives a callback after a repository transaction that marked local
/// data dirty has committed. The sync service uses it to schedule the
/// debounced push; `quiet` changes (streaming checkpoints) are recorded in
/// the dirty queue but must not wake the push loop.
abstract interface class SyncWriteObserver {
  void onLocalChange({required SyncScope scope, required bool quiet});
}
