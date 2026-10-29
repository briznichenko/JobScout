import fcntl
import signal
import threading
from contextlib import contextmanager


class ScanCancelled(BaseException):
    pass


@contextmanager
def scan_lock(database):
    database.parent.mkdir(parents=True, exist_ok=True)
    with database.with_suffix(database.suffix + ".scan.lock").open("a") as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ValueError("Another scan is already using this database; wait for it to finish") from error
        try:
            yield
        finally:
            fcntl.flock(stream, fcntl.LOCK_UN)


@contextmanager
def cancellation_scope():
    if threading.current_thread() is not threading.main_thread():
        yield
        return

    def cancel(signum, frame):
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        raise ScanCancelled()

    previous = signal.signal(signal.SIGTERM, cancel)
    try:
        yield
    finally:
        signal.signal(signal.SIGTERM, previous)
