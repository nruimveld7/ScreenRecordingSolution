from __future__ import annotations
from pathlib import Path
from datetime import datetime, timedelta
import os
import re
import shutil
import sys

_FILENAME_SAFE = re.compile(r"[^A-Za-z0-9._-]+")
_SHARE_DIR_NAME = "Recordings"


def _install_root() -> Path:
    """
    Determine where the manager is running from. When frozen (PyInstaller),
    this is the directory containing the executable; otherwise fall back to
    the project root for local dev.
    """
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parents[2]


def recordings_root(create: bool = True) -> Path:
    """
    Location of the shared recordings directory, adjacent to the manager exe.
    When create=True the directory is ensured to exist (useful during dev runs).
    """
    root = _install_root() / _SHARE_DIR_NAME
    if create:
        root.mkdir(parents=True, exist_ok=True)
    return root


def safe_name(s: str | None, fallback: str = "unknown") -> str:
    if not s:
        return fallback
    s = s.strip() or fallback
    s = _FILENAME_SAFE.sub("_", s)
    return s[:128]  # keep paths tidy


def save_upload(
    storage_root: str | os.PathLike,
    upload_filename: str,
    recording_user: str | None,
    system_name: str | None,
    data_stream,
) -> Path:
    """
    Save the uploaded file stream under:
      <storage_root>/<system_name>/<recording_user>/<YYYY-MM-DD>/<original_filename>
    Returns the final Path.
    """
    system_label = safe_name(system_name, fallback="unknown-system")
    user_label = safe_name(recording_user, fallback="unknown-user")
    day = datetime.utcnow().strftime("%Y-%m-%d")

    target_dir = Path(storage_root) / system_label / user_label / day
    target_dir.mkdir(parents=True, exist_ok=True)

    # sanitize the filename too
    fname = safe_name(
        upload_filename, fallback=f"segment_{int(datetime.utcnow().timestamp())}.mkv"
    )
    target_path = target_dir / fname

    # stream copy to disk
    with open(target_path, "wb") as f:
        shutil.copyfileobj(data_stream, f)

    return target_path


def save_upload_to_share(
    upload_filename: str,
    computer_name: str | None,
    user_session: str | None,
    data_stream,
) -> Path:
    """
    Convenience wrapper that targets the shared recordings directory next to
    the executable.
    """
    return save_upload(
        recordings_root(),
        upload_filename,
        recording_user=user_session,
        system_name=computer_name,
        data_stream=data_stream,
    )


def rotate(storage_root: str | os.PathLike, retention_days: int) -> int:
    """
    Delete files older than retention_days (by file mtime).
    Returns the count of deleted files.
    """
    days = max(0, retention_days)
    return rotate_by_age(Path(storage_root), timedelta(days=days))


def rotate_by_age(root: Path, older_than: timedelta) -> int:
    """
    Delete files whose mtime is older than 'older_than'. Also prunes any empty
    directories that remain. Returns number of deleted files.
    """
    if not root.exists():
        return 0

    cutoff = datetime.utcnow() - older_than
    deleted = 0

    for p in root.rglob("*"):
        try:
            if p.is_file():
                mtime = datetime.utcfromtimestamp(p.stat().st_mtime)
                if mtime < cutoff:
                    p.unlink(missing_ok=True)
                    deleted += 1
        except Exception:
            # Keep going; log if you add logging later
            pass

    # Clean up empty dirs (best effort)
    for dirpath, dirnames, filenames in os.walk(root, topdown=False):
        try:
            if not dirnames and not filenames:
                Path(dirpath).rmdir()
        except Exception:
            pass

    return deleted
