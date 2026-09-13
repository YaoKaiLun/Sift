import re

_TAG = re.compile(r"v\d+\.\d+(\.\d+)?")


def parse_version(github_ref, git_describe, fallback="1.0"):
    if github_ref and github_ref.startswith("refs/tags/"):
        tag = github_ref.rsplit("/", 1)[-1]
        if _TAG.fullmatch(tag):
            return tag[1:]
    if git_describe and _TAG.fullmatch(git_describe):
        return git_describe[1:]
    return fallback
