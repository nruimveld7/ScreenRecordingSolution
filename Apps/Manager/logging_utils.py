from __future__ import annotations

import datetime
import logging
import threading
from pathlib import Path
from typing import Optional, TextIO


class DailyFileHandler(logging.Handler):
    """
    Simple handler that writes to <directory>/<YYYY-MM-DD>.log without renaming.
    A new file is opened automatically when the date changes. Old files are
    pruned based on their last-modified time.
    """

    def __init__(
        self,
        directory: str,
        retention_days: int = 14,
        encoding: str = "utf-8",
    ) -> None:
        super().__init__()
        self._dir = Path(directory)
        self._dir.mkdir(parents=True, exist_ok=True)
        self._retention = max(0, retention_days)
        self._encoding = encoding
        self._current_date: Optional[datetime.date] = None
        self._stream: Optional[TextIO] = None
        self._lock = threading.RLock()
        self._last_cleanup = datetime.datetime.min
        self.terminator = "\n"

    def emit(self, record: logging.LogRecord) -> None:
        msg = self.format(record)
        with self._lock:
            self._ensure_stream()
            assert self._stream is not None
            self._stream.write(msg + self.terminator)
            self._stream.flush()
            self._maybe_cleanup()

    def _ensure_stream(self) -> None:
        today = datetime.date.today()
        if self._current_date == today and self._stream:
            return

        if self._stream:
            self._stream.close()
            self._stream = None

        target = self._dir / f"{today:%Y-%m-%d}.log"
        self._stream = open(target, "a", encoding=self._encoding)
        self._current_date = today

    def _maybe_cleanup(self) -> None:
        if self._retention <= 0:
            return

        now = datetime.datetime.now()
        if (now - self._last_cleanup).total_seconds() < 3600:
            return

        cutoff = now - datetime.timedelta(days=self._retention)
        for log_path in self._dir.glob("*.log"):
            try:
                mtime = datetime.datetime.fromtimestamp(log_path.stat().st_mtime)
                if mtime < cutoff:
                    log_path.unlink(missing_ok=True)
            except Exception:
                continue

        self._last_cleanup = now

    def close(self) -> None:
        try:
            if self._stream:
                self._stream.close()
        finally:
            self._stream = None
            super().close()
