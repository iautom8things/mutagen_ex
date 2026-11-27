#!/usr/bin/env python3
# agent-rules: generated v0.29.5
"""Filesystem access shared by the AGY advisory queue and cache pruner."""

import fcntl
import os
import re
import stat
import time
from contextlib import contextmanager, suppress
from pathlib import Path


ITEM_ID = re.compile(r"[0-9]{20}-[0-9a-f]{32}")
DIRECTORY = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
MAX_AGE = 7 * 24 * 60 * 60


def _cache_base():
    return Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache").absolute()


@contextmanager
def _directory(name, parent=None, *, create=False, private=True):
    if create:
        with suppress(FileExistsError):
            os.mkdir(name, 0o700, dir_fd=parent)
    fd = os.open(name, DIRECTORY, dir_fd=parent)
    try:
        info = os.fstat(fd)
        mode = stat.S_IMODE(info.st_mode)
        if info.st_uid != os.geteuid() or mode & 0o022 or (private and mode != 0o700):
            raise PermissionError("unsafe AGY cache directory")
        yield fd
    finally:
        os.close(fd)


@contextmanager
def _queue(*, create=False, pruning=False, nonblocking=False):
    base = _cache_base()
    if create:
        base.mkdir(parents=True, exist_ok=True, mode=0o700)
    with _directory(base, private=False) as cache:
        with _directory("agent-rules", cache, create=create, private=False) as rules:
            with _directory("agy-queue", rules, create=create) as queue:
                # Pruning must wait for a future SessionStart if the queue is busy.
                lock = fcntl.LOCK_EX if pruning else fcntl.LOCK_SH
                if pruning or nonblocking:
                    lock |= fcntl.LOCK_NB
                fcntl.flock(queue, lock)
                yield queue


def _private_file(info):
    return (stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid()
            and info.st_nlink == 1 and stat.S_IMODE(info.st_mode) == 0o600)


def _prune_conversation(conversation, cutoff):
    contexts = {}
    for context in os.listdir(conversation):
        try:
            with _directory(context, conversation) as directory:
                items = []
                for name in os.listdir(directory):
                    if not ITEM_ID.fullmatch(name.removeprefix(".")):
                        continue
                    info = os.stat(name, dir_fd=directory, follow_symlinks=False)
                    if _private_file(info):
                        if info.st_mtime >= cutoff:
                            return
                        items.append(name)
                contexts[context] = items
        except OSError:
            continue
    for context, items in contexts.items():
        with suppress(OSError):
            with _directory(context, conversation) as directory:
                for name in items:
                    with suppress(OSError):
                        os.unlink(name, dir_fd=directory)
            os.rmdir(context, dir_fd=conversation)


def prune():
    """Drop stale conversations based on item activity, during SessionStart."""
    cutoff = time.time() - MAX_AGE
    with suppress(OSError), _queue(pruning=True) as queue:
        for cid in os.listdir(queue):
            with suppress(OSError):
                with _directory(cid, queue) as conversation:
                    _prune_conversation(conversation, cutoff)
                os.rmdir(cid, dir_fd=queue)
