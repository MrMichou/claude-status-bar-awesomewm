// Shared /proc helpers for session-marker PID tracking (Linux; see issue #63).
// Markers in sessions.d/ record the session's `claude` PID so a later SessionStart
// can reap markers whose process died without SessionEnd.

const fs = require("fs");

// Resolve this hook's owning `claude` PID by walking the process ancestry in /proc
// (node → shell → claude). Returns 0 when unresolvable (non-Linux, unexpected comm) —
// the marker then stays empty and is never reaped, the pre-reaper behavior.
function claudePid() {
  let pid = process.ppid;
  for (let i = 0; i < 20 && pid > 1; i++) {
    try {
      if (fs.readFileSync(`/proc/${pid}/comm`, "utf8").trim() === "claude") return pid;
      const stat = fs.readFileSync(`/proc/${pid}/stat`, "utf8");
      pid = parseInt(stat.slice(stat.lastIndexOf(")") + 2).split(" ")[1], 10);
    } catch { return 0; }
  }
  return 0;
}

// A recorded PID counts as alive only while it is still a `claude` process: PIDs are
// recorded by matching comm == "claude" in claudePid(), so a different comm means the
// PID was recycled (typical after a reboot, where low PIDs are reused quickly).
function aliveClaude(pid) {
  try { return fs.readFileSync(`/proc/${pid}/comm`, "utf8").trim() === "claude"; }
  catch { return false; }
}

module.exports = { claudePid, aliveClaude };
