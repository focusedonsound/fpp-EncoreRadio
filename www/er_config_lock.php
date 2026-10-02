<?php
// Shared file-locking helper for encoreradio.json.
//
// Every writer here (save.php, mark_onboarding_seen.php, set_volume.php,
// spotify_callback.php) follows the same read -> merge ->
// write-to-.tmp -> rename pattern. The rename itself is atomic, but the
// read-and-merge in between isn't: two requests landing close together
// (a user clicking Save while the volume slider's own background
// live-apply write fires, or two browser tabs open on the settings page)
// can both read the same starting content, merge their own change on top
// of it independently, and whichever rename() lands second silently wins,
// discarding the other request's change entirely. No corruption (rename
// is atomic), just a lost update - and intermittent enough that it's easy
// to write off as "the page glitched" rather than recognize as a real race.
//
// A separate .lock file (not the config file itself) so a reader elsewhere
// that opens encoreradio.json directly (e.g. a script using plain
// file_get_contents, never taking this lock) is never blocked by it -
// only the writers that opt in by calling this are serialized against
// each other.

function erConfigLock($configFile) {
  $lockFile = $configFile . ".lock";
  $fh = @fopen($lockFile, 'c');
  if ($fh === false) return false;
  // Blocks (no LOCK_NB) - these writes are small and fast, and a request
  // that has to wait a few milliseconds behind another is far better than
  // one that silently loses data or gives up and reports a spurious error.
  if (!flock($fh, LOCK_EX)) {
    fclose($fh);
    return false;
  }
  return $fh;
}

function erConfigUnlock($fh) {
  // Must tolerate being called twice on the same handle: every caller
  // releases explicitly as soon as it's done (so the lock isn't held
  // across a following network call), but erConfigLockAuto()'s
  // register_shutdown_function() backstop still fires too, on that same
  // now-closed resource - confirmed on real hardware: flock() on an
  // already-fclose()'d resource throws a TypeError (not just a warning)
  // on modern PHP, which turned every single save into a logged fatal
  // error even though the response had already gone out successfully.
  // is_resource() is false once fclose() has run, so this is safe to call
  // any number of times on the same handle.
  if (!is_resource($fh)) return;
  flock($fh, LOCK_UN);
  fclose($fh);
}

// Registers the unlock as a shutdown function so it still runs no matter
// which erRespond()/exit path a caller takes after locking - each writer
// here has several early-exit validation branches between the lock and
// the final rename, and missing even one would leave the lock held for
// the rest of that PHP-FPM worker's life (until process recycle), wedging
// every subsequent save from any client until then.
function erConfigLockAuto($configFile) {
  $fh = erConfigLock($configFile);
  if ($fh !== false) {
    register_shutdown_function('erConfigUnlock', $fh);
  }
  return $fh;
}
